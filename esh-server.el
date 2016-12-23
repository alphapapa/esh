;;; esh-server.el --- Communicate with a daemon running ESH  -*- lexical-binding: t; -*-

;; Copyright (C) 2016  Clément Pit-Claudel

;; Author: Clément Pit-Claudel <clement.pitclaudel@live.com>
;; Keywords: faces, tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package contains functions than run on the server that esh-client
;; spawns.  It's mostly an eval facility plus error handling.

;;; Code:

(require 'esh)

(defvar esh-server--backtrace nil
  "Backtrace of last error during `esh-server-eval'.")

(defvar esh-server-initializing nil
  "Non-nil while the ESH server is initializing.")

(defvar esh-server-init-info 'none
  "Init info (INIT-FPATH . _) that was used to initialize the server.")

(defvar esh-server--profile nil
  "Whether to record a profile.")

(defvar esh-server--capture-backtraces nil
  "Whether to capture backtraces.
Capturing a backtrace can be very costly, because arguments can
be huge — so only do it if requested.")

(defvar esh--server-frame nil
  "Global variable holding the invisible ESH frame.")

(defun esh-server--backtrace ()
  "Retrieve a backtrace and clean it up."
  (with-temp-buffer ;; Could use a sequence of (backtrace-frame) calls
    (let ((standard-output (current-buffer)))
      (backtrace)
      (goto-char (point-min))
      (when (re-search-forward "^  esh-server--handle-error" nil t)
        (delete-region (point-min) (point-at-bol)))
      (buffer-string))))

(defun esh-server--handle-error (&rest args)
  "Handle an error in code run on the server.
This function is appropriate as a value for `debugger' (hence
ARGS).  We need this function because the server doesn't print
backtraces; thus we take a more aggressive stand and simply
intercept all errors as they happen.  We just store the backtrace
in esh--server-backtrace and rethrow the error immediately; then
the `condition-case' in `esh-server-eval' will catch the error,
unless it's nicely handled somewhere else."
  ;; Prevent recursive error catching
  (let ((debugger #'debug)
        (debug-on-quit nil)
        (debug-on-error nil)
        (debug-on-signal nil))
    ;; HACK HACK HACK: The first time the debugger is invoked, the value of
    ;; `num-nonmacro-input-events' is recorded (eval.c).  On subsequent
    ;; invocations, there's a check to see if the `num-nonmacro-input-events'
    ;; has increased.  But since all of this is running on the server, there are
    ;; no non-macro input events; and thus the debugger is only broken into
    ;; once.  To work around this, we increase `num-nonmacro-input-events' here.
    (setq num-nonmacro-input-events (1+ num-nonmacro-input-events))
    (pcase args
      (`(exit ,retv) retv)
      (`(error ,error-args)
       (when esh-server--capture-backtraces
         ;; Capturing backtraces can be very costly
         (setq esh-server--backtrace (esh-server--backtrace)))
       (signal (car error-args) (cdr error-args))))))

(defun esh-server--writeout (file form)
  "Write FORM to FILE."
  (with-temp-buffer
    (insert (prin1-to-string form))
    (write-region (point-min) (point-max) file)))

(defun esh-server-eval (form file &optional capture-backtraces)
  "Eval FORM and write result or error to FILE.
Written value can be `read' from FILE; it is either a
list (success RESULT) or a cons (error ERR BACKTRACE).  BACKTRACE
will be non-nil only if CAPTURE-BACKTRACES was non-nil."
  (condition-case err
      (let* (;; Make sure that we'll intercept all errors
             (debug-on-quit t)
             (debug-on-error t)
             (debug-on-signal t)
             (debug-ignored-errors nil)
             ;; Make sure debugger has room to execute
             (max-specpdl-size (+ 50 max-specpdl-size))
             (max-lisp-eval-depth (+ 50 max-lisp-eval-depth))
             ;; Register ourselves as the debugger
             (debugger #'esh-server--handle-error)
             ;; Possibly turn backtraces on
             (esh-server--capture-backtraces capture-backtraces)
             ;; Compute result
             (result (eval form)))
        (esh-server--writeout file `(success ,result)))
    (error (esh-server--writeout file `(error ,err ,esh-server--backtrace)))))

(defun esh-server-start-profiling ()
  "Start CPU profiling (results are saved upon exit)."
  (setq esh-server--profile t)
  (require 'profiler)
  (with-no-warnings (profiler-start 'cpu))
  (add-hook 'kill-emacs-hook #'esh-server--kill-emacs-hook))

(defun esh-server--window-system-frame-parameter ()
  "Choose an appropriate window system.
This seems to be only needed on Windows; on GNU/Linux and macOS,
the defaults seems to work fine."
  ;; (`darwin 'ns)
  ;; ((or `gnu `gnu/linux `gnu/kfreebsd) 'x)
  (when (memq system-type '(windows-nt cygwin))
    '((window-system . w32))))

(defun esh-server-init (display &optional init-info)
  "Initialize the ESH server.
Create an invisible frame on DISPLAY after loading INIT-INFO,
which should be a cons of (INIT-FPATH . CLIENT-PROVIDED-DATA).
No error checking here; we expect this to be invoked through
`esh-server-eval'."
  (setq-default load-prefer-newer t)
  (setq-default text-quoting-style 'grave)
  (let ((init-fpath (car init-info)))
    (when init-fpath
      (let ((esh-server-initializing t))
        (load-file init-fpath))))
  (setq esh--server-frame
        (make-frame `(,@(esh-server--window-system-frame-parameter)
                      (display . ,display)
                      (visibility . nil))))
  (ignore (setq esh-server-init-info init-info)))

(defun esh-server--process-to-str (in-path in-type out-type)
  "Process IN-PATH, IN-TYPE, OUT-TYPE; return a string."
  (with-selected-frame esh--server-frame
    (pcase out-type
      (`latex
       (pcase in-type
         (`mixed (esh2tex-tex-file in-path))
         (`source (esh2tex-source-file in-path))
         (_ (error "Unknown input type %S" in-type))))
      (`latex-pv
       (pcase in-type
         (`mixed (esh2tex-tex-file-pv in-path))
         (_ (error "Unsupported input type %S for --precompute-verbs" in-type))))
      (`html
       (pcase in-type
         (`mixed (esh2html-html-file in-path))
         (_ (error "Unsupported input type %S for HTML backend" in-type))))
      (_ (error "Unknown output type %S" out-type)))))

(defun esh-server-process (in-path out-path in-type out-type)
  "Process IN-PATH, saving results to OUT-PATH.

If OUT-PATH is nil, return results as a string.  IN-TYPE
indicates the kind of document being processed.  It should be one
of the following:

* \\='mixed (a full document containing source code)
* \\='source (a single source file)

OUT-TYPE indicates the desired output format (one of \\='latex,
\\'latex-pv, or \\='html).

No error checking here; we expect this to be invoked through
`esh-server-eval'."
  (let ((str (esh-server--process-to-str in-path in-type out-type)))
    (if out-path
        (with-temp-file out-path
          (insert str))
      str)))

(defun esh-server--kill-emacs-hook ()
  "Save profiler report if `esh-server--profile' is on."
  (when esh-server--profile
    (ignore-errors
      (let ((prof-name (format-time-string "esh--%Y-%m-%d--%H-%M-%S.prof")))
        (with-no-warnings
          (profiler-write-profile (profiler-cpu-profile) prof-name))))))

(provide 'esh-server)
;;; esh-server.el ends here

;; Local Variables:
;; checkdoc-arguments-in-order-flag: nil
;; End:
