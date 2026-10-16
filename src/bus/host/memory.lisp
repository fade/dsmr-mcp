;;;; src/bus/host/memory.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; How the host service tells memory pressure from noise, and which worker it
;;;; asks a session pool to give up first.
;;;;
;;;; I read two signals together, once a second. The kernel's pressure stall
;;;; figures (/proc/pressure/memory) say how much of the last ten seconds tasks
;;;; spent waiting on memory, so they move within seconds of the host starting
;;;; to thrash. They say nothing while memory drains slowly and nobody stalls
;;;; yet, which is what MemAvailable in /proc/meminfo catches. A host without
;;;; the pressure file still has the MemAvailable rule.
;;;;
;;;; Relief has to start early. Saving a stateful worker's world costs, for a
;;;; moment, up to twice that worker's footprint, so a host that waits until
;;;; it is nearly out of memory has no room left to save anything, and
;;;; systemd-oomd ends up choosing what dies instead. Fresh idle workers go
;;;; first: they hold nothing a session has built, and a pool brings one back in
;;;; about a tenth of a second. Stateful idle workers follow, least recently
;;;; used first, the larger first when two were last used at the same moment.
;;;; A worker serving a call, one a pool refused lately, one already asked
;;;; about, and every worker of a server that has gone are never offered.
;;;;
;;;; The threshold defaults are UNMEASURED starting points. I set them well
;;;; below systemd-oomd's limit of 60% stall for 30 s so the service acts long
;;;; before oomd would, but nothing has yet measured them under load: they are
;;;; to be retuned from measurements taken on a host running a full fleet.
;;;; Every one of them can be changed from the service's environment, read when
;;;; the service starts.
;;;;
;;;; Entering pressure takes two stall readings in a row, or one reading of low
;;;; available memory, and leaving it takes a calm that has held for a while,
;;;; so a single spike neither starts nor stops relief. The classifier and the
;;;; ranking are pure functions of the readings, the records and a time the
;;;; caller passes in, in the manner of the breaker in conditions.lisp, so they
;;;; are tested by handing them numbers rather than by starving a host.

(defpackage #:dsmr-bus-host/src/bus/host/memory
  (:use #:cl)
  (:local-nicknames (#:pool-records #:dsmr-mcp/src/hermetic/pool-records)
                    (#:hostfiles #:dsmr-mcp/src/bus/hostfiles))
  (:import-from #:uiop)
  (:export
   ;; readings
   #:memory-readings
   #:make-memory-readings
   #:memory-readings-some-avg10
   #:memory-readings-full-avg10
   #:memory-readings-mem-total-kb
   #:memory-readings-mem-available-kb
   #:memory-readings-swap-total-kb
   #:memory-readings-swap-free-kb
   #:parse-psi-text
   #:parse-meminfo-text
   #:read-memory-readings
   #:available-fraction
   ;; thresholds
   #:memory-thresholds
   #:make-memory-thresholds
   #:memory-thresholds-enter-some
   #:memory-thresholds-enter-full
   #:memory-thresholds-enter-available
   #:memory-thresholds-leave-some
   #:memory-thresholds-leave-available
   #:memory-thresholds-hold-seconds
   #:memory-thresholds-min-kill-age-seconds
   #:thresholds-from-environment
   ;; classifier
   #:memory-state
   #:make-memory-state
   #:memory-state-verdict
   #:memory-state-psi-hits
   #:memory-state-since
   #:memory-state-clear-since
   #:classify-memory
   ;; ranking
   #:rank-candidates))

(in-package #:dsmr-bus-host/src/bus/host/memory)

;;; ------------------------------------------------------------------ readings

(defstruct (memory-readings (:copier nil))
  "One reading of the host's memory. SOME-AVG10 and FULL-AVG10 are the
   percentages of the last ten seconds in which some or all tasks stalled on
   memory, or NIL without a pressure file; the sizes are in kilobytes, or NIL
   when /proc/meminfo did not give them."
  (some-avg10 nil)
  (full-avg10 nil)
  (mem-total-kb nil)
  (mem-available-kb nil)
  (swap-total-kb nil)
  (swap-free-kb nil))

(defun %parse-decimal (text)
  "The non-negative number TEXT spells as digits with at most one decimal
   point, as an exact rational, or NIL when it spells anything else. Nothing
   is handed to the Lisp reader."
  (let* ((s (string-trim '(#\Space #\Tab #\Newline #\Return) text))
         (dot (position #\. s))
         (whole (subseq s 0 (or dot (length s))))
         (frac (if dot (subseq s (1+ dot)) "")))
    (flet ((digits-p (part)
             (every (lambda (ch) (char<= #\0 ch #\9)) part)))
      (when (and (plusp (length s))
                 (or (plusp (length whole)) (plusp (length frac)))
                 (digits-p whole)
                 (digits-p frac))
        (+ (if (plusp (length whole)) (parse-integer whole) 0)
           (if (plusp (length frac))
               (/ (parse-integer frac) (expt 10 (length frac)))
               0))))))

(defun %lines (text)
  "The lines of TEXT."
  (uiop:split-string text :separator (string #\Newline)))

(defun parse-psi-text (text)
  "The avg10 figures of the some and full lines of TEXT, as the kernel writes
   /proc/pressure/memory, as two values. Either is NIL when its line is
   missing or unreadable."
  (let ((some nil) (full nil))
    (dolist (line (%lines text))
      (let* ((fields (remove "" (uiop:split-string line :separator " ")
                             :test #'string=))
             (avg10 (find-if (lambda (f) (uiop:string-prefix-p "avg10=" f))
                             (rest fields)))
             (value (and avg10 (%parse-decimal (subseq avg10 6)))))
        (when value
          (cond ((equal (first fields) "some") (setf some (float value 1.0)))
                ((equal (first fields) "full") (setf full (float value 1.0)))))))
    (values some full)))

(defun parse-meminfo-text (text)
  "The sizes the service reads from TEXT, as /proc/meminfo writes it, as a
   plist of :MEM-TOTAL-KB :MEM-AVAILABLE-KB :SWAP-TOTAL-KB :SWAP-FREE-KB, each
   an integer number of kilobytes or NIL."
  (let ((labels '(("MemTotal:" . :mem-total-kb)
                  ("MemAvailable:" . :mem-available-kb)
                  ("SwapTotal:" . :swap-total-kb)
                  ("SwapFree:" . :swap-free-kb)))
        (found '()))
    (dolist (line (%lines text))
      (dolist (entry labels)
        (when (and (uiop:string-prefix-p (car entry) line)
                   (not (getf found (cdr entry))))
          (let ((value (ignore-errors
                        (parse-integer line :start (length (car entry))
                                            :junk-allowed t))))
            (when (typep value '(integer 0))
              (setf (getf found (cdr entry)) value))))))
    (loop for (nil . key) in labels
          append (list key (getf found key)))))

(defun read-memory-readings (&key (psi-path "/proc/pressure/memory")
                                  (meminfo-path "/proc/meminfo"))
  "Read the host's memory now, from PSI-PATH and MEMINFO-PATH. A file that
   cannot be read leaves its fields NIL, so a kernel without pressure figures
   still yields the sizes."
  (flet ((text (path)
           (or (ignore-errors (uiop:read-file-string path)) "")))
    (multiple-value-bind (some full) (parse-psi-text (text psi-path))
      (let ((sizes (parse-meminfo-text (text meminfo-path))))
        (make-memory-readings :some-avg10 some
                              :full-avg10 full
                              :mem-total-kb (getf sizes :mem-total-kb)
                              :mem-available-kb (getf sizes :mem-available-kb)
                              :swap-total-kb (getf sizes :swap-total-kb)
                              :swap-free-kb (getf sizes :swap-free-kb))))))

(defun available-fraction (readings)
  "The share of memory still available, between 0 and 1, or NIL when READINGS
   lack either size or the total is 0."
  (let ((total (memory-readings-mem-total-kb readings))
        (available (memory-readings-mem-available-kb readings)))
    (and (integerp total) (plusp total)
         (integerp available)
         (float (/ available total) 1.0))))

;;; ---------------------------------------------------------------- thresholds

(defstruct (memory-thresholds (:copier nil))
  "Where pressure starts and stops. Pressure is entered when the some figure
   reaches ENTER-SOME or the full figure reaches ENTER-FULL on two readings in
   a row, or at once when the available share falls below ENTER-AVAILABLE. It
   clears once the some figure has stayed below LEAVE-SOME and the available
   share above LEAVE-AVAILABLE for HOLD-SECONDS. A fresh worker younger than
   MIN-KILL-AGE-SECONDS is never offered for stopping. The defaults are
   unmeasured starting points."
  (enter-some 10.0)
  (enter-full 2.0)
  (enter-available 0.12)
  (leave-some 3.0)
  (leave-available 0.20)
  (hold-seconds 30)
  (min-kill-age-seconds 10))

(defparameter *threshold-variables*
  '(("DSMR_PRESSURE_ENTER_SOME" :enter-some :stall)
    ("DSMR_PRESSURE_ENTER_FULL" :enter-full :stall)
    ("DSMR_PRESSURE_ENTER_AVAILABLE_PERCENT" :enter-available :percent)
    ("DSMR_PRESSURE_LEAVE_SOME" :leave-some :stall)
    ("DSMR_PRESSURE_LEAVE_AVAILABLE_PERCENT" :leave-available :percent)
    ("DSMR_PRESSURE_HOLD_SECONDS" :hold-seconds :hold)
    ("DSMR_PRESSURE_MIN_KILL_AGE_SECONDS" :min-kill-age-seconds :age))
  "Each environment variable that sets a threshold, the threshold it sets, and
   the kind of value it takes.")

(defun %threshold-value (text kind)
  "The threshold TEXT gives for KIND, or NIL when it gives none. A stall figure
   is a percentage from 0 to 100 taken as given; an available share is a
   percentage from 0 to 100 divided by 100; the hold is a whole number of
   seconds of at least 1, the minimum kill age one of at least 0."
  (let ((value (%parse-decimal text)))
    (when value
      (ecase kind
        (:stall (and (<= value 100) (float value 1.0)))
        (:percent (and (<= value 100) (float (/ value 100) 1.0)))
        (:hold (and (integerp value) (>= value 1) value))
        (:age (and (integerp value) value))))))

(defun %kind-description (kind)
  "What a value of KIND has to be, for a warning."
  (ecase kind
    (:stall "a percentage from 0 to 100")
    (:percent "a percentage from 0 to 100")
    (:hold "a whole number of seconds, at least 1")
    (:age "a whole number of seconds")))

(defun thresholds-from-environment (&key (getenv #'uiop:getenv))
  "The thresholds the environment sets, as (values thresholds warnings).

   Each variable in *THRESHOLD-VARIABLES* that GETENV answers with a usable
   value sets its threshold; an unset or empty one leaves the default. A value
   that cannot be used leaves the default too, and adds a warning string
   naming the variable, for the caller to log. The service calls this once,
   when it starts."
  (let ((initargs '())
        (warnings '()))
    (loop for (name key kind) in *threshold-variables*
          for text = (funcall getenv name)
          unless (or (null text) (zerop (length (string-trim " " text))))
            do (let ((value (%threshold-value text kind)))
                 (if value
                     (setf initargs (list* key value initargs))
                     (push (format nil "~A=~S is not ~A; using the default."
                                   name text (%kind-description kind))
                           warnings))))
    (values (apply #'make-memory-thresholds initargs)
            (nreverse warnings))))

;;; ---------------------------------------------------------------- classifier

(defstruct (memory-state (:copier nil))
  "Where the classifier stands. VERDICT is :OK or :PRESSURE; PSI-HITS counts
   stall readings in a row while the verdict is :OK; SINCE is when pressure
   was entered; CLEAR-SINCE is when the calm that may end it began."
  (verdict :ok)
  (psi-hits 0)
  (since nil)
  (clear-since nil))

(defun classify-memory (readings state now &optional (thresholds (make-memory-thresholds)))
  "Decide from READINGS taken at NOW, in seconds, whether the host is under
   memory pressure, given the classifier STATE. Returns (values verdict
   new-state), the verdict :OK or :PRESSURE. Pure: STATE is not modified and
   nothing is read but the arguments.

   From :OK, a stall reading at or above a threshold counts a hit and any
   other reading clears the count; two hits in a row, or an available share
   below its threshold, enter pressure. Under pressure, a reading whose some
   figure is below its leave threshold, or absent, and whose available share
   is above its own counts as calm; pressure clears once calm has held for the
   hold time, and any reading that is not calm starts the hold again. Without
   a memory total there is no available share, so that rule can neither enter
   pressure nor clear it."
  (let ((some (memory-readings-some-avg10 readings))
        (full (memory-readings-full-avg10 readings))
        (available (available-fraction readings)))
    (ecase (memory-state-verdict state)
      (:ok
       (let* ((stalled (or (and some (>= some (memory-thresholds-enter-some thresholds)))
                           (and full (>= full (memory-thresholds-enter-full thresholds)))))
              (hits (if stalled (1+ (memory-state-psi-hits state)) 0)))
         (if (or (>= hits 2)
                 (and available
                      (< available (memory-thresholds-enter-available thresholds))))
             (values :pressure (make-memory-state :verdict :pressure :psi-hits hits
                                                  :since now))
             (values :ok (make-memory-state :verdict :ok :psi-hits hits)))))
      (:pressure
       (let ((calm (and available
                        (> available (memory-thresholds-leave-available thresholds))
                        (or (null some)
                            (< some (memory-thresholds-leave-some thresholds)))))
             (since (memory-state-since state)))
         (if calm
             (let ((clear-since (or (memory-state-clear-since state) now)))
               (if (>= (- now clear-since) (memory-thresholds-hold-seconds thresholds))
                   (values :ok (make-memory-state :verdict :ok))
                   (values :pressure (make-memory-state :verdict :pressure :since since
                                                        :clear-since clear-since))))
             (values :pressure (make-memory-state :verdict :pressure :since since))))))))

;;; ------------------------------------------------------------------- ranking

(defun %recently-refused-p (worker now refusal-seconds)
  "True when a pool refused WORKER fewer than REFUSAL-SECONDS before NOW."
  (let ((at (getf worker :refused-at)))
    (and (realp at) (< (- now at) refusal-seconds))))

(defun %candidate (stem worker now pending refusal-seconds min-kill-age
                   &key hibernate-full)
  "WORKER of the server STEM as a candidate plist, or NIL when it may not be
   offered at NOW. With HIBERNATE-FULL, the server keeps all the hibernated
   workers it may, so a stateful worker is not offered."
  (let* ((id (getf worker :id))
         (spawned (let ((at (getf worker :spawned-at)))
                    (and (realp at) at)))
         (last (getf worker :last-activity))
         (stateful (and (getf worker :stateful) t)))
    (when (and (typep id '(integer 1))
               (eq (getf worker :state) :bound)
               (not (getf worker :busy))
               (not (%recently-refused-p worker now refusal-seconds))
               (not (member (cons stem id) pending :test #'equal))
               (not (and stateful hibernate-full))
               (or stateful
                   (>= (if spawned (- now spawned) 0) min-kill-age)))
      (list :stem stem
            :worker-id id
            :pid (getf worker :pid)
            :session (getf worker :session)
            :action (if stateful :hibernate :kill)
            :stateful stateful
            :last-activity (cond ((realp last) last)
                                 (spawned spawned)
                                 (t now))
            :pss-kb nil))))

(defun %ranks-before-p (a b)
  "True when candidate A is to be acted on before candidate B."
  (flet ((action-rank (c) (if (eq (getf c :action) :kill) 0 1))
         (pss (c) (or (getf c :pss-kb) -1)))
    (cond ((/= (action-rank a) (action-rank b))
           (< (action-rank a) (action-rank b)))
          ((/= (getf a :last-activity) (getf b :last-activity))
           (< (getf a :last-activity) (getf b :last-activity)))
          ((/= (pss a) (pss b))
           (> (pss a) (pss b)))
          ((string/= (getf a :stem) (getf b :stem))
           (string< (getf a :stem) (getf b :stem)))
          (t (< (getf a :worker-id) (getf b :worker-id))))))

(defun rank-candidates (records now &key (pss-fn #'pool-records:read-pss-kb)
                                         (owner-alive-p #'hostfiles:process-matches-p)
                                         (pending '())
                                         (refusal-seconds 300)
                                         (min-kill-age 10))
  "The workers in RECORDS, the pools' published worker records, that may be
   relieved at NOW, in the order to act on them. Pure: nothing is read but the
   arguments and what PSS-FN and OWNER-ALIVE-P answer.

   Each candidate is a plist of :STEM :WORKER-ID :PID :SESSION :ACTION
   :STATEFUL :LAST-ACTIVITY :PSS-KB. Fresh idle workers come first with the
   action :KILL, then stateful idle workers with :HIBERNATE, each group by
   activity, oldest first, and the larger PSS first on a tie. Activity is the
   worker's last activity, else its spawn time, else NOW.

   A worker is never offered when it is not :BOUND, is serving a call, was
   refused fewer than REFUSAL-SECONDS ago, is named in PENDING, a list of
   (stem . worker-id) with requests outstanding, or belongs to a server
   OWNER-ALIVE-P, called with the server's pid and start time, says has gone.
   A stateful worker is not offered either when its server's record says
   :HIBERNATE-FULL, since that server would refuse to save another world.
   A fresh worker spawned fewer than MIN-KILL-AGE seconds ago, or with no
   spawn time, is not offered for stopping, so a worker spawned for a call
   still being set up is left alone. PSS-FN reads a pid's proportional memory
   in kilobytes and is called only for workers that are offered."
  (let ((candidates '()))
    (dolist (record records)
      (let ((pid (getf record :server-pid))
            (start (getf record :server-start)))
        (when (and (typep pid '(integer 1))
                   (typep start '(integer 0))
                   (funcall owner-alive-p pid start))
          (let ((stem (format nil "~D-~D" pid start)))
            (dolist (worker (getf record :workers))
              (let ((candidate (%candidate stem worker now pending
                                           refusal-seconds min-kill-age
                                           :hibernate-full
                                           (getf record :hibernate-full))))
                (when candidate
                  (let ((worker-pid (getf candidate :pid)))
                    (setf (getf candidate :pss-kb)
                          (and (typep worker-pid '(integer 1))
                               (funcall pss-fn worker-pid))))
                  (push candidate candidates))))))))
    (sort (nreverse candidates) #'%ranks-before-p)))
