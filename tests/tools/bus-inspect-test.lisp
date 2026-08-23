;;;; tests/tools/bus-inspect-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Coverage for the bus-inspect verb, and for the promise made when the older
;;;; bus status verb was superseded rather than replaced.
;;;;
;;;; Everything here is asserted against the verb's real response on a bus this
;;;; test made, driven to the point where it puts JSON on the wire and parsed
;;;; back the way a client reads it. A walker asserted against a constructed
;;;; sample proves the walker reads a sample; the gap between what a verb builds
;;;; and what its encoder emits is exactly where a value turns into something a
;;;; reader will misread, and only the round trip covers it.
;;;;
;;;; The walk runs twice, over a healthy bus and over one carrying a position
;;;; that cannot be a position in the log as it stands. The fields that state
;;;; the interesting bounds only appear in the second case, so a walk that only
;;;; ever saw the first has not looked at them.
;;;;
;;;; The negative control carries as much weight as the conformance assertion.
;;;; Without a mutated response nothing ever watches the walker reject, and an
;;;; empty violation list is then equally consistent with a walker that never
;;;; looked at this payload shape at all.
;;;;
;;;; The scratch state root lives under the cache directory rather than the
;;;; temporary directory. The rotation answer correlates the kernel's lock table
;;;; to a file by a device column learned from the filesystem, and a memory
;;;; filesystem answers differently from the disk filesystem the real bus roots
;;;; live on. Exercising the verb only in the temporary directory would be green
;;;; and would say nothing about where it has to work.
;;;;
;;;; Its name is kept short for a reason that is easy to undo by accident. A bus
;;;; puts a unix-domain socket under its own root, and a socket address carries
;;;; its path in a fixed field with 107 usable characters, so every character of
;;;; the state root is charged against that budget. A readable directory name
;;;; here fits under a home cache directory and does not fit under the one the
;;;; build sets inside the checkout, where the same test refuses to make a bus at
;;;; all. Where even the short name will not fit, this states that and stands
;;;; down rather than failing in a way that reads as a fault in the verb.

;; Package evolution guard: drop a prior incarnation so a reload picks up the
;; current import set rather than stale symbols.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/tools/bus-inspect-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/tools/bus-inspect-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:jzon #:com.inuoe.jzon)
                    (#:selector #:dsmr-mcp/src/bus/selector)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:cursor #:dsmr-mcp/src/bus/cursor)
                    (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:archive #:dsmr-mcp/src/bus/archive))
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/tools/status-fields
                #:field-contract-violations)
  (:import-from #:dsmr-mcp/src/tools/bus-inspect
                #:bus-inspect-tool)
  (:import-from #:dsmr-mcp/src/tools/bus-status
                #:bus-status-tool)
  (:import-from #:dsmr-mcp/src/tools/bus-helpers
                #:disconnect-session-bus)
  (:import-from #:dsmr-mcp/src/state
                #:make-session)
  (:import-from #:dsmr-mcp/tests/support/env-fixture
                #:with-clean-resolution-env))

(in-package #:dsmr-mcp/tests/tools/bus-inspect-test)

;;; ---------------------------------------------------------------------------
;;; Fixture
;;; ---------------------------------------------------------------------------

(defun scratch-directory (tag)
  "A uniquely named directory of this test's own, on the filesystem the real bus
   roots live on.

   TAG is one character, and the whole name is as short as it can be while
   staying unique, because the state root is charged against the socket-path
   budget described at the head of this file.

   The suffix is drawn from a state seeded per call: SBCL's default random state
   is identical in every fresh image, so without the seeding two runs walk the
   same names and a tree left by an earlier run turns an absence assertion into
   a flake."
  (loop
    (let ((dir (merge-pathnames
                (format nil "dsmr-bi-~A~8,'0X/" tag
                        (random #xFFFFFFFF (make-random-state t)))
                (uiop:xdg-cache-home))))
      (unless (probe-file dir)
        (ensure-directories-exist dir)
        (return dir)))))

(defun socket-path-fits-p (state-root)
  "True when a bus under STATE-ROOT can have a socket the kernel will accept.

   Measured against the same bound the bus itself enforces, so this answers the
   question the bus is about to answer rather than a guess at it."
  (<= (length (namestring (merge-pathnames "dsmr-mcp/bus/submit.ipc" state-root)))
      selector:+max-socket-path-length+))

(defun serve-bus-in-process (paths)
  "Elect a broker on PATHS and serve it on a background thread. Returns a thunk
   that stops it and joins the thread."
  (broker:ensure-bus-dirs paths)
  (let* ((br (broker:start-broker paths :block nil))
         (stop nil)
         (thread (sb-thread:make-thread
                  (lambda () (broker:serve-broker br (lambda () stop)))
                  :name "bus-inspect-test-broker")))
    (lambda ()
      (setf stop t)
      (ignore-errors (sb-thread:join-thread thread))
      (ignore-errors (broker:stop-broker br)))))

(defmacro with-scratch-bus ((paths session) &body body)
  "Run BODY with XDG_STATE_HOME pointed at a scratch directory, a broker serving
   the bus derived from it, PATHS bound to that bus and SESSION bound to a
   session rooted at a scratch project directory.

   Both directories are removed and every participant the session opened is
   disconnected however BODY leaves, so a failing assertion cannot strand a
   broker thread or a bus root a later run would read."
  (let ((state (gensym "STATE")) (root (gensym "ROOT"))
        (saved (gensym "SAVED")) (stop (gensym "STOP")))
    `(with-clean-resolution-env
       (let ((,state (scratch-directory "s"))
             (,root (scratch-directory "p"))
             (,saved (uiop:getenv "XDG_STATE_HOME")))
         (unwind-protect
              (if (socket-path-fits-p ,state)
                  (progn
                    (setf (uiop:getenv "XDG_STATE_HOME") (namestring ,state))
                    (let* ((,paths (broker:make-bus-paths))
                           (,stop (serve-bus-in-process ,paths))
                           (,session (make-session :id "bus-inspect"
                                                   :project-root ,root)))
                      (declare (ignorable ,paths))
                      (unwind-protect (progn ,@body)
                        (ignore-errors (disconnect-session-bus ,session))
                        (funcall ,stop))))
                  (skip ("this cache directory leaves no room for a bus socket ~
                          within the ~D characters a socket address allows, so ~
                          no bus can be made here to inspect"
                         selector:+max-socket-path-length+)))
           (setf (uiop:getenv "XDG_STATE_HOME") (or ,saved ""))
           (ignore-errors (uiop:delete-directory-tree
                           ,state :validate t :if-does-not-exist :ignore))
           (ignore-errors (uiop:delete-directory-tree
                           ,root :validate t :if-does-not-exist :ignore)))))))

(defun plant-cursor-above-head (paths name position)
  "Write a cursor for NAME at POSITION, above the head of this bus's log.

   The production shape of the fault: the log was sealed, the next cohort
   numbers from one again, and an identity still holds the position it had
   before. Asserted here rather than assumed, so a plant that stopped planting
   would fail rather than quietly leave the unhealthy case untested."
  (let ((log (broker:bus-paths-wal paths)))
    (setf (cursor:cursor-value
           (cursor:make-subscriber name log (broker:cursor-path-for paths name)))
          position)
    (assert (> position (wal:scan log)))
    name))

;;; ---------------------------------------------------------------------------
;;; Driving the verbs
;;; ---------------------------------------------------------------------------

(defun args (&rest kvs)
  "An MCP arguments hash-table from alternating string-key/value pairs."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k ht) v))
    ht))

(defun invoke (class session kvs)
  "Invoke the tool CLASS for SESSION and return its result payload, unwrapped
   from the JSON-RPC envelope."
  (let ((tool (make-instance class :session session)))
    (gethash "result" (tool-handle tool 1 (apply #'args kvs)))))

(defun inspect-result (session &rest kvs)
  (invoke 'bus-inspect-tool session kvs))

(defun status-result (session &rest kvs)
  (invoke 'bus-status-tool session kvs))

(defun answer (payload)
  "The bus answer, parsed back the way a client reads it.

   A parse of the emitted JSON rather than a peek at the hash-table the verb
   built. Everything between the two is where an encoder turns a value into
   something a reader will misread, and covering that gap is why the walk runs
   here at all."
  (jzon:parse (gethash "text" (aref (gethash "content" payload) 0))))

(defun error-type (payload)
  (and (gethash "isError" payload) (gethash "error_type" payload)))

(defun answer-group (answer name)
  (gethash name answer))

(defun field (answer group-name key)
  (gethash key (answer-group answer group-name)))

(defun field-value (answer group-name key)
  (gethash "value" (field answer group-name key)))

(defun keys-of (ht)
  "HT's keys in a stable order, so a field-list comparison reads the same twice."
  (sort (loop for k being the hash-keys of ht collect k) #'string<))

(defun row-named (rows name)
  (find name rows :key (lambda (row) (gethash "name" row)) :test #'string=))

(defun mentions (field needle)
  "True when FIELD's stated bound carries NEEDLE.

   Matched on a phrase rather than a whole sentence, so the bound can be reworded
   for clarity without turning this red. What is asserted is what the bound has
   to say, not how it says it."
  (let ((bound (gethash "does_not_establish" field)))
    (and (stringp bound) (search needle bound) t)))

;;; ---------------------------------------------------------------------------
;;; The conformance walk over the real response
;;; ---------------------------------------------------------------------------

(define-test the-bus-answer-conforms-to-the-field-contract
  "Every field in the bus answer states its own bounds, walked over the payload
   the verb emitted and a client parses back.

   Driven twice on one bus: once while it is healthy, and once with a position
   planted above the head. The stranded case fills fields the healthy one leaves
   empty, so a walk that only ever saw the healthy shape has not read them."
  (with-scratch-bus (paths session)
    (let ((healthy (inspect-result session)))
      (is eq nil (gethash "isError" healthy)
          "the verb answers rather than refusing")
      (is equal '() (field-contract-violations (answer healthy))
          "the answer for a healthy bus conforms"))
    (plant-cursor-above-head paths "probe/above" 260)
    (let ((stranded (inspect-result session)))
      (is eq nil (gethash "isError" stranded)
          "and it still answers with a stranded position on the bus")
      (is equal '() (field-contract-violations (answer stranded))
          "the answer for a bus carrying a stranded position conforms too"))))

(define-test a-bound-deleted-from-the-real-answer-is-reported
  "The negative control on the conformance walk.

   One key is removed from one classification in a response the verb genuinely
   produced, and the walker has to name the field it was taken from. Without
   this, an empty violation list above is equally consistent with a walker that
   never looked at this payload shape."
  (with-scratch-bus (paths session)
    (let ((answer (answer (inspect-result session))))
      (remhash "does_not_establish" (field answer "broker" "running"))
      (let ((violations (field-contract-violations answer)))
        (true violations "deleting a stated bound produces a violation")
        (true (find-if (lambda (v) (search "broker.running" v)) violations)
              "the violation names the field the bound was taken from")))
    (plant-cursor-above-head paths "probe/above" 260)
    (let ((answer (answer (inspect-result session))))
      (remhash "does_not_establish" (field answer "cursors" "stranded_count"))
      (let ((violations (field-contract-violations answer)))
        (true violations "the same deletion on the stranded count is reported")
        (true (find-if (lambda (v) (search "cursors.stranded_count" v)) violations)
              "and that violation names the cursor field")))))

;;; ---------------------------------------------------------------------------
;;; What the answer carries
;;; ---------------------------------------------------------------------------

(define-test the-answer-carries-each-bus-question-under-its-own-key
  "Broker identity and survivability, whether rotation is armed, the log's own
   identity, the position inventory and who is visible each arrive under a key
   of their own, as fields carrying values rather than as bare scalars."
  (with-scratch-bus (paths session)
    (let ((answer (answer (inspect-result session))))
      (dolist (name '("broker" "rotation" "log" "cursors" "identities"))
        (true (hash-table-p (answer-group answer name))
              (format nil "~A is present as a group of its own" name)))
      (dolist (spec '(("broker" "running") ("broker" "pid") ("broker" "parent_pid")
                      ("broker" "uptime_seconds") ("broker" "source_revision")
                      ("rotation" "armed") ("rotation" "holders")
                      ("log" "head") ("log" "generation") ("log" "archives")
                      ("cursors" "count") ("cursors" "stranded_count")
                      ("cursors" "cursors")
                      ("identities" "members") ("identities" "unenrolled")
                      ("identities" "watch_beat")))
        (let ((f (field answer (first spec) (second spec))))
          (true (hash-table-p f)
                (format nil "~A.~A is a reported field" (first spec) (second spec)))
          (true (nth-value 1 (gethash "value" f))
                (format nil "~A.~A carries a value" (first spec) (second spec))))))))

(define-test a-position-above-the-head-reaches-the-answer-as-stranded
  "The fault the aggregator can see has to survive being rendered.

   A surface that took the inventory and dropped the reason on the way to the
   wire would satisfy every conformance assertion above, because a field with no
   fault to report conforms perfectly well."
  (with-scratch-bus (paths session)
    (let ((clean (answer (inspect-result session))))
      (is = 0 (field-value clean "cursors" "stranded_count")
          "nothing is stranded before anything is planted"))
    (plant-cursor-above-head paths "probe/above" 260)
    (let* ((answer (answer (inspect-result session)))
           (rows (coerce (field-value answer "cursors" "cursors") 'list))
           (row (row-named rows "probe%2Fabove")))
      (true row "the planted position appears in the inventory")
      (is = 260 (gethash "cursor" row))
      (true (gethash "above_head" row)
            "and it is flagged as a position past the end of the log")
      (is string= "cursor-above-head" (gethash "stranded_reason" row))
      (is = 1 (field-value answer "cursors" "stranded_count")
          "the count says one position cannot be a position in this log"))))

(define-test the-log-fields-move-when-the-log-is-replaced
  "The head and the generation are read rather than assumed. Sealing the log
   moves both, which is what makes the pair worth reporting: a position recorded
   against the log before the seal is below the new head and reads as merely
   behind."
  (with-scratch-bus (paths session)
    (let ((log (broker:bus-paths-wal paths)))
      (loop for i from 1 to 20 do (wal:append-record log i "x"))
      (let ((before (answer (inspect-result session))))
        (is = 20 (field-value before "log" "head"))
        (is = 0 (field-value before "log" "generation")
            "an unrotated log is on the generation it started at")
        (is = 0 (field-value before "log" "archive_count")))
      (archive:archive-wal log (broker:bus-paths-root paths) :now 1000)
      (loop for i from 1 to 3 do (wal:append-record log i "x"))
      (let ((after (answer (inspect-result session))))
        (is = 3 (field-value after "log" "head")
            "the replacement log numbers from one again")
        (is = 1 (field-value after "log" "generation")
            "and only the generation carries that the log is not the one before")
        (is = 1 (field-value after "log" "archive_count"))
        (is = 1 (length (field-value after "log" "archives"))
            "the sealed log is listed")))))

(define-test the-revision-field-says-it-has-not-compared-the-working-tree
  "The one field whose name is a comparison it deliberately does not perform.

   The conformance walk proves only that the bound is present and not empty. The
   question behind this field is whether a broker is serving stale code, and a
   field that names staleness as its purpose while quietly not establishing
   staleness is the same false confidence the whole surface exists to remove, so
   this one gets an assertion on its text."
  (with-scratch-bus (paths session)
    (let ((answer (answer (inspect-result session))))
      (true (mentions (field answer "broker" "source_revision") "working tree")
            "the revision states that it settles nothing about the working tree"))))

;;; ---------------------------------------------------------------------------
;;; The argument contract, asserted rather than assumed
;;; ---------------------------------------------------------------------------

(define-test an-unusable-bus-selector-is-refused-and-nothing-else-is-reported-instead
  "A bus that cannot be resolved is refused outright. Reporting on the session's
   own bus instead would answer a question nobody asked, under a name that says
   it answered theirs."
  (with-scratch-bus (paths session)
    (let ((empty (inspect-result session "bus" "")))
      (is string= "invalid-argument" (error-type empty)
          "an empty bus name is refused"))
    (let ((malformed (inspect-result session "bus" "no/such/bus")))
      (is string= "invalid-argument" (error-type malformed)
          "and so is a name that cannot become a bus directory"))
    (let ((ok (inspect-result session)))
      (is eq nil (gethash "isError" ok)
          "while omitting the argument answers on this session's own bus"))))

(define-test without-a-project-root-there-is-no-namespace-to-answer-under
  "The bus gives an identity its namespace from the project root, so a session
   with none has no participant to report for and says which call fixes it."
  (with-clean-resolution-env
    (let ((rootless (invoke 'bus-inspect-tool (make-session :id "rootless") '())))
      (is string= "project-root-not-set" (error-type rootless)))))

;;; ---------------------------------------------------------------------------
;;; The supersession, proved non-breaking
;;; ---------------------------------------------------------------------------

(defparameter +status-fields-before-supersession+
  '("agent_id" "agent_name" "broker_running" "bus" "content" "live_watcher"
    "namespace" "pending" "stable" "watcher_age_seconds" "watcher_status")
  "Every key the older bus status verb returned before it was superseded.

   Written out as a list rather than checked one key at a time, because the
   promise made when that verb was kept was that nothing was taken away, and a
   test that asserts one field at a time cannot see a field that vanished.")

(define-test the-superseded-verb-still-returns-everything-it-returned-before
  "Supersession changed what the verb says about itself and nothing about what
   it answers. A caller written against the old reply keeps working."
  (with-scratch-bus (paths session)
    (let ((payload (status-result session)))
      (is eq nil (gethash "isError" payload)
          "the superseded verb still answers")
      (dolist (key +status-fields-before-supersession+)
        (true (nth-value 1 (gethash key payload))
              (format nil "~A is still returned" key)))
      (is equal (sort (copy-list (cons "superseded_by"
                                       +status-fields-before-supersession+))
                      #'string<)
          (keys-of payload)
          "and the reply is the old field set plus the successor, with nothing else added or dropped")
      (is = 0 (gethash "pending" payload)
          "the pending count is still a plain number a caller can read"))))

(define-test the-superseded-verb-names-its-successor-in-the-reply
  "A caller relaying an answer onward carries the reply and not the tool
   description, so the reply is where the pointer has to be."
  (with-scratch-bus (paths session)
    (let ((supersession (gethash "superseded_by" (status-result session))))
      (true (hash-table-p supersession) "the reply carries a supersession note")
      (is string= "bus-inspect" (gethash "verb" supersession)
          "which names the verb that answers the inventory question")
      (true (search "moment in time" (gethash "reports" supersession))
            "and says what this reply is")
      (true (search "delivery filters" (gethash "pending" supersession))
            "and states in its own terms why the pending number can differ from a receive"))))
