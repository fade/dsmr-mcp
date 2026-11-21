;;;; src/release.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; What a release image needs to know about itself: the release directory it
;;;; runs from, how its ASDF registry is sealed, and whether it is sealed.

(defpackage #:dsmr-mcp/src/release
  (:use #:cl)
  (:export #:release-root
           #:seal-source-registry
           #:sealed-p))

(in-package #:dsmr-mcp/src/release)

(defun %package-inferred-search ()
  "The symbol naming ASDF's package-inferred system search function."
  (uiop:find-symbol* '#:sysdef-package-inferred-system-search
                     '#:asdf/package-inferred-system))

(defun release-root ()
  "Return the directory DSMR_RELEASE_ROOT names, as a physical directory
pathname, or NIL when the variable is unset, empty, or names no existing
directory. Reads the environment on every call."
  (let ((value (uiop:getenv "DSMR_RELEASE_ROOT")))
    (when (and value (plusp (length value)))
      (let ((dir (ignore-errors (uiop:directory-exists-p
                                 (uiop:ensure-directory-pathname value)))))
        (and dir (ignore-errors (truename dir)))))))

(defun seal-source-registry ()
  "Seal this image's ASDF registry and return no values.

Empties ASDF:*CENTRAL-REGISTRY* and ASDF:*DEFAULT-SOURCE-REGISTRIES*, leaves
the package-inferred search function as the only system search function, and
clears the source registry. Loaded systems stay usable: loading one again is a
no-op and SYSTEM-RELATIVE-PATHNAME still answers. Finding or loading a system
the image has not loaded signals ASDF/FIND-COMPONENT:MISSING-COMPONENT, and
ASDF:CLEAR-SOURCE-REGISTRY does not undo the seal."
  (setf asdf:*central-registry* nil
        asdf:*default-source-registries* nil
        asdf:*system-definition-search-functions*
        (list (%package-inferred-search)))
  (asdf:clear-source-registry)
  (values))

(defun sealed-p ()
  "True when the image is sealed: the package-inferred search function is the
only system search function and both the central and default source
registries are empty."
  (and (equal asdf:*system-definition-search-functions*
              (list (%package-inferred-search)))
       (null asdf:*central-registry*)
       (null asdf:*default-source-registries*)))
