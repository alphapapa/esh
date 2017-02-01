;;; esh.el --- Use Emacs to highlight snippets in LaTeX and HTML documents -*- lexical-binding: t; -*-

;; Copyright (C) 2016  Clément Pit-Claudel

;; Author: Clément Pit-Claudel <clement.pitclaudel@live.com>
;; Package-Requires: ((emacs "24.3"))
;; Package-Version: 0.1
;; Keywords: faces
;; URL: https://github.com/cpitclaudel/esh2tex

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

;; ESH is an extensible framework for exporting Emacs' syntax highlighting to
;; other languages, and for using Emacs to highlight code snippets embedded in
;; documents.  Its LaTeX backend is a replacement for lstlistings, minted, etc.\
;; that uses Emacs' major-modes to syntax-highlight code blocks in your
;; documents.
;;
;; See URL `https://github.com/cpitclaudel/esh' for usage instructions.

;;; Code:

;; Can't depend on external packages
(require 'color)
(require 'tabify)
(require 'cl-lib)
(require 'esh-interval-tree)

(defconst esh--script-full-path
  (or (and load-in-progress load-file-name)
      (bound-and-true-p byte-compile-current-file)
      (buffer-file-name))
  "Full path of this script.")

(defconst esh--directory
  (file-name-directory esh--script-full-path)
  "Full path to directory of this script.")

;;; Misc utils

(defun esh--find-auto-mode (fpath)
  "Find mode for FPATH.
There's no way to use the standard machinery (`set-auto-mode')
without also initializing the mode, which prevents us from
reusing the same buffer to process multiple source files.
Instead, go through `auto-mode-alist' ourselves."
  (let ((mode (assoc-default fpath auto-mode-alist 'string-match)))
    (unless mode
      (error "No mode found for %S in auto-mode-alist" fpath))
    (when (consp mode)
      (error "Unexpected auto-mode spec for %S: %S" mode fpath))
    mode))

(defun esh--filter-cdr (val alist)
  "Remove conses in ALIST whose `cdr' is VAL."
  ;; FIXME phase this out once Emacs 25 is everywhere
  (let ((kept nil))
    (while alist
      (let ((top (pop alist)))
        (when (not (eq (cdr top) val))
          (push top kept))))
    (nreverse kept)))

(defvar esh-name-to-mode-alist nil
  "Alist of block name → mode function.")

(defun esh-add-language (language mode)
  "Teach ESH about a new LANGUAGE, highlighted with MODE.
For example, calling (esh-add-language \"ocaml\" \\='tuareg-mode)
allows you to use `tuareg-mode' for HTML blocks tagged
“src-ocaml”, or for LaTeX blocks tagged “ESH: ocaml”."
  (unless (stringp language)
    (user-error "`esh-add-language': language %S should be a string" language))
  (unless (symbolp mode)
    (user-error "`esh-add-language': mode %S should be a function" mode))
  (add-to-list 'esh-name-to-mode-alist (cons language mode)))

(defun esh--resolve-mode-fn (fn-name)
  "Translate FN-NAME to a function symbol.
Uses `esh-name-to-mode-alist'."
  (or (cdr (assoc fn-name esh-name-to-mode-alist))
      (intern (concat fn-name "-mode"))))

(defun esh-add-keywords (forms &optional how)
  "Pass FORMS and HOW to `font-lock-add-keywords'.
See `font-lock-keywords' for information about the format of
elements of FORMS.  This function does essentially the same thing
as `font-lock-add-keywords', with nicer indentation, a simpler
call signature, and a workaround for an Emacs bug."
  (declare (indent 0))
  ;; Work around Emacs bug #24176
  (setq font-lock-major-mode major-mode)
  (font-lock-add-keywords nil forms how))

(defun esh--remove-final-newline ()
  "Hide last newline of current buffer, if present.
The line is hidden, rather than removed entirely, because it may
have interesting text properties (e.g. `line-height')."
  (goto-char (point-max))
  ;; There may not be a final newline in standalone mode
  (when (eq (char-before) ?\n)
    (put-text-property (1- (point)) (point) 'invisible t)))

(defun esh--insert-file-contents (fname)
  "Like (`insert-file-contents' FNAME), but allow all local variables."
  (let ((enable-local-variables :all))
    (insert-file-contents fname)))

(defun esh--merge-sorted (s1 s2 pred)
  "Merge two lists S1 S2 sorted by PRED."
  (let ((acc nil))
    (while (or s1 s2)
      (cond
       ((and s1 s2)
        (if (funcall pred (car s1) (car s2))
            (push (pop s1) acc)
          (push (pop s2) acc)))
       (s1 (push (pop s1) acc))
       (s2 (push (pop s2) acc))))
    (nreverse acc)))

(defun esh--insert (&rest strs)
  "Insert all non-nil elements of STRS."
  (dolist (str strs)
    (when str
      (insert str))))

(defun esh--shuffle (v)
  "Shuffle vector V (in place)."
  (let ((pos (1- (length v))))
    (while (> pos 0)
      (let ((target (random pos)))
        (cl-psetf (aref v pos) (aref v target)
                  (aref v target) (aref v pos)))
      (setq pos (1- pos))))
  v)

(defmacro esh--pp (x)
  "Pretty-print X and its value, then return the value."
  (declare (debug t))
  (let ((xx (make-symbol "x")))
    `(progn (prin1 ',x)
            (princ "\n")
            (let ((,xx ,x))
              (pp ,xx)
              (princ "\n")
              ,xx))))

(defun esh--join (strs sep)
  "Joins STRS with SEP."
  (mapconcat #'identity strs sep))

(defmacro esh--doplist (bindings &rest body)
  "Bind PROP and VAR to pairs in PLIST and run BODY.
BINDINGS should be a list (PROP VAL PLIST).

\(fn (PROP VAL PLIST) BODY...)"
  (declare (indent 1) (debug ((symbolp symbolp form) body)))
  (pcase-let ((plist (make-symbol "plist"))
              (`(,prop ,val ,plist-expr) bindings))
    `(let ((,plist ,plist-expr))
       (while ,plist
         (let ((,prop (pop ,plist))
               (,val (pop ,plist)))
           ,@body)))))

(defun esh--plist-delete-all (needle haystack)
  "Remove key NEEDLE from plist HAYSTACK."
  (let ((plist nil))
    (esh--doplist (prop val haystack)
      (unless (eq prop needle)
        (push prop plist)
        (push val plist)))
    (nreverse plist)))

;;; Copying buffers

(defun esh--number-or-0 (x)
  "Return X if X is a number, 0 otherwise."
  (if (numberp x) x 0))

(defun esh--augment-overlay (ov)
  "Return a list of three values: the priorities of overlay OV, and OV."
  (let ((pr (overlay-get ov 'priority)))
    (if (consp pr)
        (list (esh--number-or-0 (car pr)) (esh--number-or-0 (cdr pr)) ov)
      (list (esh--number-or-0 pr) 0 ov))))

(defun esh--augmented-overlay-< (ov1 ov2)
  "Compare two lists OV1 OV2 produced by `esh--augment-overlay'."
  (or (< (car ov1) (car ov2))
      (and (= (car ov1) (car ov2))
           (< (cadr ov1) (cadr ov2)))))

(defun esh--buffer-overlays (buf)
  "Collects overlays of BUF, in order of increasing priority."
  (let* ((ovs (with-current-buffer buf (overlays-in (point-min) (point-max))))
         (augmented (mapcar #'esh--augment-overlay ovs))
         (sorted (sort augmented #'esh--augmented-overlay-<)))
    (mapcar #'cl-caddr sorted)))

(defun esh--commit-overlays (buf)
  "Copy overlays of BUF into current buffer's text properties.
We need to do this, because get-char-text-property considers at
most one overlay."
  (dolist (ov (esh--buffer-overlays buf))
    (let* ((start (overlay-start ov))
           (end (overlay-end ov))
           (props (overlay-properties ov))
           (face (plist-get props 'face)))
      (when face
        (setq props (esh--plist-delete-all 'face props))
        (font-lock-prepend-text-property start end 'face face))
      (add-text-properties start end props))))

(defun esh--copy-buffer (buf)
  "Copy contents and overlays of BUF into current buffer."
  (insert-buffer-substring buf)
  (setq-local tab-width (buffer-local-value 'tab-width buf))
  (esh--commit-overlays buf))

(defmacro esh--with-copy-of-current-buffer (&rest body)
  "Run BODY in a temporary copy of the current buffer."
  (declare (indent 0) (debug t))
  (let ((buf (make-symbol "buf")))
    `(let ((,buf (current-buffer)))
       (with-temp-buffer
         (esh--copy-buffer ,buf)
         ,@body))))

;;; Segmenting a buffer

(defun esh--buffer-ranges-from (start prop)
  "Create a stream of buffer ranges from START.
Ranges are pairs of START..END positions in which all characters
have the same value of PROP or, if PROP is nil, of all
properties."
  (let ((ranges nil)
        (end nil))
    (while (setq end (if prop (next-single-property-change start prop)
                       (next-property-change start)))
      (push (cons start end) ranges)
      (setq start end))
    (push (cons start (point-max)) ranges)
    (nreverse ranges)))

(defun esh--buffer-ranges (&optional prop)
  "Create a stream of buffer ranges.
Ranges are pairs of START..END positions in which all characters
have the same value of PROP or, if PROP is nil, of all
properties."
  (esh--buffer-ranges-from 1 prop))

;;; Extracting faces and properties

(defun esh--extract-props (props pos)
  "Read PROPS from POS as an ALIST of (PROP . VAL)."
  (let ((alist nil))
    (esh--doplist (prop val (text-properties-at pos))
      (when (and (memq prop props) val)
        (push (cons prop val) alist)))
    (nreverse alist)))

(defun esh--face-get (face attribute)
  "Read ATTRIBUTE from (potentially anonymous) FACE.
Does not take inheritance into account."
  (cond ((facep face)
         (face-attribute face attribute))
        ((listp face)
         (if (plist-member face attribute)
             (plist-get face attribute)
           'unspecified))
        (t (error "Invalid face %S" face))))

(defun esh--single-face-attribute (face attribute)
  "Read ATTRIBUTE from (potentially anonymous) FACE.
Takes inheritance into account."
  (let* ((attr (esh--face-get face attribute))
         (rel-p (face-attribute-relative-p attribute attr))
         (inherit (esh--face-get face :inherit)))
    (if (and rel-p
             (not (eq inherit 'default))
             (or (listp inherit) (facep inherit)))
        (let ((merge-with (esh--single-face-attribute inherit attribute)))
          (merge-face-attribute attribute attr merge-with))
      attr)))

(defun esh--faces-attribute (faces attribute)
  "Read ATTRIBUTE from FACES.
Faces is a list of (possibly anonymous) faces."
  (let ((attr 'unspecified))
    (while (and faces (face-attribute-relative-p attribute attr))
      (let ((merge-with (esh--single-face-attribute (pop faces) attribute)))
        (setq attr (merge-face-attribute attribute attr merge-with))))
    attr))

(defun esh--as-list (x)
  "Wrap X in a list, if needed."
  (if (listp x) x (list x)))

(defun esh--faces-at-point (pos)
  "Compute list of faces at POS."
  ;; No need to consider overlay properties here, since they've been converted
  ;; to text properties in previous steps.
  (esh--as-list (get-text-property pos 'face)))

;; Caching this function speeds things up by about 5%
(defun esh--extract-face-attributes (face-attributes faces)
  "Extract FACE-ATTRIBUTES from FACES."
  (esh--filter-cdr 'unspecified
                (mapcar (lambda (attr) (cons attr (esh--faces-attribute faces attr)))
                        face-attributes)))

(defun esh--extract-pos-face-attributes (face-attributes pos)
  "Extract FACE-ATTRIBUTES from POS."
  (let ((faces (esh--faces-at-point pos)))
    (and faces ;; Empty list of faces → no face attributes
         (esh--extract-face-attributes face-attributes faces))))

;;; Massaging properties

(defun esh--commit-compositions-1 (from to str)
  "Commit composition STR to FROM .. TO."
  (let ((props (text-properties-at from)))
    (goto-char from)
    (delete-region from to)
    (insert str)
    (set-text-properties from (+ from (length str)) props)
    (remove-text-properties from (+ from (length str)) '(composition))))

(defun esh--parse-composition (components)
  "Translate composition COMPONENTS into a string."
  (let ((chars (list (aref components 0)))
        (nrules (/ (length components) 2)))
    (dotimes (nrule nrules)
      (let* ((rule (aref components (+ 1 (* 2 nrule))))
             (char (aref components (+ 2 (* 2 nrule)))))
        (pcase rule
          (`(Br . Bl) (push char chars))
          (_ (error "Unsupported composition COMPONENTS")))))
    (concat (nreverse chars))))

(defun esh--commit-compositions ()
  "Apply compositions in current buffer.
This replaced each composed string by its composition, forgetting
the original string."
  (pcase-dolist (`(,from . ,to) (reverse (esh--buffer-ranges 'composition)))
    (let ((comp-data (find-composition from nil nil t)))
      (when comp-data
        (pcase-let* ((`(,_ ,_ ,components ,relative-p ,_ ,_) comp-data)
                     (str (if relative-p (concat components)
                            (esh--parse-composition components))))
          (esh--commit-compositions-1 from to str))))))

(defun esh--mark-newlines (&optional additional-props)
  "Add `esh--newline' and ADDITIONAL-PROPS text properties to each \\n.
The value of `esh--newline' is either `empty' or `non-empty' (we
need this to add a dummy element on empty lines to prevent LaTeX
from complaining about underful hboxes).  Adding these properties
also makes it easy to group ranges by line, which yields a
significant speedup when processing long files (compared to
putting all lines in one large interval tree)."
  (goto-char (point-min))
  (while (search-forward "\n" nil t)
    ;; (point-at-bol 0) is beginning of previous line
    ;; (match-beginning 0) is end of previous line
    ;; Inclusion of (point) prevents collapsing of adjacent properties
    (let* ((empty (= (point-at-bol 0) (match-beginning 0)))
           (newline (cons (point) (if empty 'empty 'non-empty))))
      (add-text-properties (match-beginning 0) (match-end 0)
                           `(esh--newline ,newline ,@additional-props)))))

;;; Constructing a stream of events

(defun esh--annotate-ranges (ranges text-props face-attrs)
  "Annotate each range in RANGES with a property alist.
Returns a list of (START END ALIST); the keys of ALIST are
properties in TEXT-PROPS or face attributes in FACE-ATTRS; its
values are the values of these properties.  START is inclusive;
END is exclusive."
  (let ((acc nil))
    (pcase-dolist (`(,start . ,end) ranges)
      (let* ((props-alist (esh--extract-props text-props start))
             (attrs-alist (esh--extract-pos-face-attributes face-attrs start))
             (merged-alist (nconc attrs-alist props-alist)))
        (push (list start end merged-alist) acc)))
    (nreverse acc)))

(defun esh--ranges-to-events (ranges props)
  "Generate opening and closing events from annotated RANGES.
Each returned element has one of the following forms:
  (\\='open POSITION (PROPERTY . VALUE))
  (\\='close POSITION (PROPERTY . VALUE))
Each PROPERTY is one of PROPS."
  (let ((events nil)
        (prev-alist nil)
        (prev-end nil))
    (pcase-dolist (`(,start ,end ,alist) ranges)
      (let ((break-here (or (assq 'esh--break prev-alist) (assq 'esh--break alist))))
        (dolist (prop props)
          (let ((old (assq prop prev-alist))
                (new (assq prop alist)))
            (unless (and (not break-here) (equal (cdr old) (cdr new)))
              (when old
                (push `(close ,start ,old) events))
              (when new
                (push `(open ,start ,new) events))))))
      (setq prev-end end)
      (setq prev-alist alist))
    (dolist (pair prev-alist)
      (push `(close ,prev-end ,pair) events))
    (nreverse events)))

(defun esh--event-property (event)
  "Read property changed by EVENT."
  (car (nth 2 event)))

(defun esh--partition-ranges-rev (ranges property)
  "Partition RANGES into lists separated by intervals marked with PROPERTY.
Return a list (in reverse order of buffer position); each element
is a list (BOL EOL RANGES)."
  (let ((lines nil)
        (cur-line nil)
        (cur-bol (point-min)))
    (dolist (range ranges)
      (push range cur-line)
      (when (assq property (nth 2 range))
        (let ((end (cadr range)))
          (push `(,cur-bol ,end ,(nreverse cur-line)) lines)
          (setq cur-line nil cur-bol end))))
    (when cur-line ;; empty if buffer has final newline
      (push `(,cur-bol ,(point-max) ,(nreverse cur-line)) lines))
    lines))

;;; Building property trees

(defun esh--events-to-intervals (events priority-ranking)
  "Parse sequence of EVENTS into lists of intervals.
Returns a list of lists suitable for consumption by
`esh--intervals-to-tree' and containing one entry per property in
PRIORITY-RANKING."
  (let ((ints-tbl (make-hash-table :test #'eq)))
    (dolist (property priority-ranking)
      (puthash property nil ints-tbl))
    (dolist (event events)
      (pcase event
        (`(open ,pos ,annot)
         ;; `car' of (gethash … …) becomes a partially constructed interval…
         (push `(,pos nil . ,annot) (gethash (car annot) ints-tbl)))
        (`(close ,pos ,annot)
         ;; …which gets completed here:
         (esh-assert (equal annot (cddr (car (gethash (car annot) ints-tbl)))))
         (setf (cadr (car (gethash (car annot) ints-tbl))) pos))))
    (let ((int-lists nil))
      (dolist (property priority-ranking)
        (push (nreverse (gethash property ints-tbl)) int-lists))
      (nreverse int-lists))))

(defun esh--intervals-to-tree (int-lists low high)
  "Construct an interval tree from text ranges in INT-LISTS.
INT-LISTS should be a list; each of its elements should be of the
form (FROM TO . ANNOTATION).  The FROM bound is inclusive; the TO
bound is exclusive.  Arguments LOW and HIGH are the boundaries of
the union of all intervals in INT-LISTS."
  (random "esh") ;; Seed the RNG to get deterministic results
  (let ((tree (esh-interval-tree-new low high)))
    (dolist (ints int-lists)
      (setq ints (esh--shuffle (vconcat ints)))
      (dotimes (n (length ints))
        (pcase (aref ints n)
          (`(,from ,to . ,annot)
           (setq tree (esh-interval-tree-add annot from to tree))))))
    tree))

;;; High-level interface to tree-related code

(defun esh--buffer-to-property-trees
    (text-props face-attrs priority-ranking range-filter)
  "Construct a list of property trees from the current buffer.
TEXT-PROPS and FACE-ATTRS specify which properties to keep track
of.  PRIORITY-RANKING ranks all these properties in order of
tolerance to splitting (if a property comes late in this list,
ESH will try to preserve this property's spans when resolving
conflicts).  RANGE-FILTER is applied to the list of (annotated)
ranges in the buffer before constructing property trees.  If the
buffer contains spans annotated with `esh--break', this function
will construct one property tree per buffer region delimited by
these annotated spans.  Splitting is needed because in Emacs text
properties can overlap in ways that are not representable as a
tree.  Result is influenced by
`esh-interval-tree-nest-annotations'."
  (let* ((flat-trees nil)
         (ranges (esh--buffer-ranges))
         (ann-ranges (esh--annotate-ranges ranges text-props face-attrs)))
    (mapc range-filter ann-ranges)
    (pcase-dolist (`(,bol ,eol ,ranges)
                   (esh--partition-ranges-rev ann-ranges 'esh--break))
      (let* ((events (esh--ranges-to-events ranges priority-ranking))
             (ints (esh--events-to-intervals events priority-ranking))
             (tree (esh--intervals-to-tree ints bol eol)))
        (setq flat-trees (esh-interval-tree-flatten-acc tree flat-trees))))
    (mapcar (lambda (tr) (esh--tree-map-attrs #'esh--normalize-suppress-defaults tr))
            flat-trees)))

;;; Fontifying

(defun esh--font-lock-ensure ()
  "Wrapper around `font-lock-ensure'."
  (if (fboundp 'font-lock-ensure)
      (font-lock-ensure)
    (with-no-warnings (font-lock-fontify-buffer))))

(defconst esh--missing-mode-template
  (concat ">>> (void-function %S); did you forget to `require'"
          " a dependency, or to restart the server? <<<%s"))

(defun esh--missing-mode-error-msg (mode)
  "Construct an error message about missing MODE."
  (propertize (format esh--missing-mode-template mode "  ")
              'face 'error 'font-lock-face 'error))

(defvar esh--temp-buffers nil
  "Alist of (MODE . BUFFER).
These are temporary buffers, used for highlighting.")

(defun esh--kill-temp-buffers ()
  "Kill buffers in `esh--temp-buffers'."
  (mapc #'kill-buffer (mapcar #'cdr esh--temp-buffers))
  (setq esh--temp-buffers nil))

(defun esh--make-temp-buffer (mode)
  "Get temp buffer for MODE from `esh--temp-buffers'.
If no such buffer exist, create one and add it to BUFFERS.  In
all cases, the buffer is erased, and a message is added to it if
the required mode isn't available."
  (save-match-data
    (let ((buf (cdr (assq mode esh--temp-buffers)))
          (mode-boundp (fboundp mode)))
      (unless buf
        (setq buf (generate-new-buffer " *temp*"))
        (with-current-buffer buf
          (funcall (if mode-boundp mode #'fundamental-mode)))
        (push (cons mode buf) esh--temp-buffers))
      (with-current-buffer buf
        (erase-buffer)
        (unless mode-boundp
          (insert (esh--missing-mode-error-msg mode))))
      buf)))

(defvar esh-pre-highlight-hook nil)
(defvar esh-post-highlight-hook nil) ;; FIXME document these

(defun esh--export-buffer (export-fn)
  "Refontify current buffer, then invoke EXPORT-FN.
EXPORT-FN should do the actual exporting."
  (run-hook-with-args 'esh-pre-highlight-hook)
  (esh--font-lock-ensure)
  (run-hook-with-args 'esh-post-highlight-hook)
  (funcall export-fn))

(defun esh--export-str (str mode-fn export-fn)
  "Fontify STR in a MODE-FN buffer, then invoke EXPORT-FN.
EXPORT-FN should do the actual exporting."
  (with-current-buffer (esh--make-temp-buffer mode-fn)
    (insert str)
    (esh--export-buffer export-fn)))

(defun esh--export-file (source-path export-fn)
  "Fontify contents of SOURCE-PATH, then invoke EXPORT-FN."
  (let ((mode-fn (esh--find-auto-mode source-path)))
    (with-current-buffer (esh--make-temp-buffer mode-fn)
      (esh--insert-file-contents source-path)
      (esh--export-buffer export-fn))))

;;; Cleaning up face attributes and text properties

(defun esh--normalize-color (color)
  "Return COLOR as a hex string."
  (unless (member color '("unspecified-fg" "unspecified-bg" "" nil))
    (let ((color (if (= (aref color 0) ?#) color
                   (apply #'color-rgb-to-hex (color-name-to-rgb color)))))
      (substring (upcase color) 1))))

(defun esh--normalize-underline (underline)
  "Normalize UNDERLINE."
  (pcase underline
    (`nil nil)
    (`t '(nil . line))
    ((pred stringp) `(,underline . line))
    ((pred listp) `(,(esh--normalize-color (plist-get underline :color)) .
                    ,(or (plist-get underline :style) 'line)))
    (_ (error "Unexpected underline %S" underline))))

(defun esh--normalize-weight (weight)
  "Normalize WEIGHT."
  (pcase weight
    ((or `thin `ultralight `ultra-light) 100)
    ((or `extralight `extra-light) 200)
    ((or `light) 300)
    ((or `demilight `semilight `semi-light `book) 400)
    ((or `normal `medium `regular) 500)
    ((or `demi `demibold `semibold `semi-bold) 600)
    ((or `bold) 700)
    ((or `extrabold `extra-bold `black) 800)
    ((or `ultrabold `ultra-bold) 900)
    (_ (error "Unexpected weight %S" weight))))

(defun esh--normalize-height (height)
  "Normalize HEIGHT to a relative (float) height."
  (let* ((default-height (face-attribute 'default :height))
         (height (merge-face-attribute :height height default-height)))
    (unless (eq height default-height)
      (/ height (float default-height)))))

(defun esh--normalize-slant (slant)
  "Normalize SLANT."
  (pcase slant
    ((or `italic `oblique `normal) slant)
    (_ (error "Unexpected slant %S" slant))))

(defun esh--normalize-box (box)
  "Normalize face attribute BOX.
Numeric values are undocumented, but `face-attribute' sometimes
returns 1 instead of t."
  (pcase box
    (`nil nil)
    (`t `(1 nil nil))
    ((pred stringp) `(1 ,box nil))
    ((pred numberp) `(,box nil nil))
    ((pred listp) `(,(or (plist-get box :line-width) 1)
                    ,(esh--normalize-color (plist-get box :color))
                    ,(plist-get box :style)))
    (_ (error "Unexpected box %S" box))))

(defun esh--normalize-attribute (property value)
  "Normalize VALUE of PROPERTY."
  (pcase property
    (:foreground (esh--normalize-color value))
    (:background (esh--normalize-color value))
    (:underline (esh--normalize-underline value))
    (:weight (esh--normalize-weight value))
    (:height (esh--normalize-height value))
    (:slant (esh--normalize-slant value))
    (:box (esh--normalize-box value))
    (_ value)))

(defun esh--normalize-suppress-defaults (property value)
  "Normalize VALUE of PROPERTY.
`:foreground' and `:background' values that match the `default'
face are suppressed."
  (setq value (esh--normalize-attribute property value))
  (unless (and (memq property '(:foreground :background))
               (let ((default (face-attribute 'default property)))
                 (equal value (esh--normalize-attribute property default))))
    value))

(defun esh--normalize-defaults (property value)
  "Normalize the pair PROPERTY: VALUE of the `default' face.
Useful when exporting the properties of the default face,
e.g. when rendering a buffer as HTML, htmlfontify-style."
  (setq value (esh--normalize-attribute property value))
  (unless (equal value (pcase property
                         (:weight 500)
                         (:slant 'normal)))
    value))

(defun esh--tree-map-attrs-1 (filter attrs)
  "Apply FILTER to each attribute pair in ATTRS."
  (if (consp (car attrs))
      (mapcar (pcase-lambda (`(,k . ,v)) (cons k (funcall filter k v))) attrs)
    (pcase-let ((`(,k . ,v) attrs))
      (cons k (funcall filter k v)))))

(defun esh--tree-map-attrs (filter tree)
  "Apply FILTER to attributes of each tag node in TREE."
  (pcase tree
    (`(text . ,_) tree)
    (`(tag ,attrs . ,trees)
     `(tag ,(esh--tree-map-attrs-1 filter attrs) .
           ,(mapcar (lambda (tr) (esh--tree-map-attrs filter tr)) trees)))
    (_ (error "Unexpected tree %S" tree))))

;;; Producing LaTeX

(defconst esh--latex-props
  '(display invisible line-height esh--newline esh--break))
(defconst esh--latex-face-attrs
  '(:underline :background :foreground :weight :slant :box :height))

(defconst esh--latex-priorities
  `(;; Fine to split
    ,@'(esh--break line-height :underline :foreground :weight :height :background)
    ;; Should not split
    ,@'(:slant :box display esh--newline invisible))
  "Priority order for text properties in LaTeX export.
See `esh--resolve-event-conflicts'.")

(eval-and-compile
  (defvar esh--latex-specials
    '(;; Special characters
      (?$ . "\\$") (?% . "\\%") (?& . "\\&")
      (?{ . "\\{") (?} . "\\}") (?_ . "\\_") (?# . "\\#")
      ;; http://tex.stackexchange.com/questions/67997/
      (?\\ . "\\textbackslash{}") (?^ . "\\textasciicircum{}")
      (?~ . "\\textasciitilde{}")
      ;; A few ligatures
      (?` . "{`}") (?' . "{'}") (?< . "{<}") (?> . "{>}")
      ;; Characters that behave differently in inline and block modes
      (?\s . "\\ESHSpace{}") (?- . "\\ESHDash{}"))))

(defvar esh--latex-specials-re
  (eval-when-compile
    (regexp-opt-charset (mapcar #'car esh--latex-specials))))

(defun esh--latex-substitute-special (m)
  "Get replacement for LaTeX special M."
  ;; If this become slows, use a vector and index by (aref m 0)
  (cdr (assq (aref m 0) esh--latex-specials)))

(defun esh--latex-substitute-specials (str)
  "Escape LaTeX specials in STR."
  (replace-regexp-in-string
   esh--latex-specials-re #'esh--latex-substitute-special str t t))

(defvar esh--latex-escape-alist nil
  "Alist of additional ‘char → LaTeX string’ mappings.")

(defun esh-latex-add-unicode-substitution (char-str latex-cmd)
  "Register an additional ‘unicode char → LaTeX command’ mapping.
CHAR-STR is a one-character string; LATEX-CMD is a latex command."
  (unless (and (stringp char-str) (eq (length char-str) 1))
    (user-error "%S: %S should be a one-character string"
                'esh-latex-add-unicode-substitution char-str))
  (add-to-list 'esh--latex-escape-alist (cons (aref char-str 0) latex-cmd)))

(defun esh--latex-escape-1 (char)
  "Escape CHAR for use with pdfLaTeX."
  (unless (featurep 'esh-latex-escape)
    (load-file (expand-file-name "esh-latex-escape.el" esh--directory)))
  (or (cdr (assq char esh--latex-escape-alist))
      (let ((repl (gethash char (with-no-warnings esh-latex-escape-table))))
        (and repl (format "\\ESHMathSymbol{%s}" repl)))))

(defun esh--latex-escape-unicode-char (char)
  "Replace currently matched CHAR with an equivalent LaTeX command."
  (let* ((translation (esh--latex-escape-1 (aref char 0))))
    (unless translation
      (error "No LaTeX equivalent found for %S.
Use (esh-latex-add-unicode-substitution %S %S) to add one"
             char char "\\someCommand"))
    (format "\\ESHUnicodeSubstitution{%s}" translation)))

(defun esh--latex-wrap-special-char (char)
  "Wrap CHAR in \\ESHSpecialChar{…}."
  (format "\\ESHSpecialChar{%s}" char))

(defvar esh-substitute-unicode-symbols nil
  "If non-nil, attempt to substitute Unicode symbols in code blocks.
Symbols are replaced by their closest LaTeX equivalent.  This
option is most useful with pdfLaTeX; with XeLaTeX or LuaLaTeX, it
should probably be turned off (customize \\ESHFallbackFont
instead).")

(defun esh--latex-wrap-non-ascii (str)
  "Wrap non-ASCII characters of STR.
If `esh-substitute-unicode-symbols' is nil, wrap non-ASCII characters into
\\ESHSpecialChar{}.  Otherwise, replace them by their LaTeX equivalents
and wrap them in \\ESHUnicodeSubstitution{}."
  ;; TODO benchmark against trivial loop
  (let* ((range "[^\000-\177]"))
    (if esh-substitute-unicode-symbols
        (replace-regexp-in-string range #'esh--latex-escape-unicode-char str t t)
      (replace-regexp-in-string range #'esh--latex-wrap-special-char str t t))))

(defun esh--mark-non-ascii ()
  "Tag non-ASCII characters of current buffer.
Puts text property `non-ascii' on non-ascii characters."
  (goto-char (point-min))
  (while (re-search-forward "[^\000-\177]" nil t)
    ;; Need property values to be distinct, hence (point)
    (put-text-property (match-beginning 0) (match-end 0) 'non-ascii (point))))

(defun esh--latex-range-filter (range)
  "Filter properties of RANGE.
Remove most of the properties on ranges marked with
`esh--newline' (keep only `invisible' and `line-height'
properties), and remove `line-height' properties on others."
  (let ((alist (cl-caddr range)))
    (cond
     ((assq 'esh--newline alist)
      (let ((new-alist nil))
        (dolist (pair alist)
          (when (memq (car pair) '(invisible line-height esh--newline esh--break))
            (push pair new-alist)))
        (setf (cl-caddr range) new-alist)))
     ((assq 'line-height alist)
      (setf (cl-caddr range) (assq-delete-all 'line-height alist))))))

(defun esh--escape-for-latex (str)
  "Escape LaTeX special characters in STR."
  (esh--latex-wrap-non-ascii (esh--latex-substitute-specials str)))

(defvar esh--latex-source-buffer-for-export nil
  "Buffer that text nodes point to.")

(defun esh--latex-export-text-node (start end)
  "Insert escaped text from range START..END.
Text is read from `esh--latex-source-buffer-for-export'."
  (insert
   (esh--escape-for-latex
    (with-current-buffer esh--latex-source-buffer-for-export
      (buffer-substring-no-properties start end)))))

(defun esh--latex-export-wrapped (before trees after)
  "Export TREES, wrapped in BEFORE and AFTER."
  (insert before)
  (mapc #'esh--latex-export-tree trees)
  (insert after))

(defun esh--latex-export-wrapped-if (val before-fmt trees after)
  "Export TREES, possibly wrapped.
If VAL is non-nil, wrap SUBTREES in (format BEFORE-FMT VAL) and
AFTER."
  (declare (indent 1))
  (if (null val)
      (mapc #'esh--latex-export-tree trees)
    (esh--latex-export-wrapped (format before-fmt val) trees after)))

(defun esh--latex-export-tag-node (property val subtrees)
  "Export SUBTREES wrapped in a LaTeX implementation of PROPERTY: VAL."
  (pcase property
    (:foreground
     (esh--latex-export-wrapped-if val
       "\\textcolor[HTML]{%s}{" subtrees "}"))
    (:background
     ;; FIXME: Force all lines to have the the same height?
     ;; Could use \\vphantom{'g}\\smash{…}
     (esh--latex-export-wrapped-if val
       "\\colorbox[HTML]{%s}{" subtrees "}"))
    (:weight
     (esh--latex-export-wrapped
      (cond
       ((< val 500) "\\ESHWeightLight{")
       ((> val 500) "\\ESHWeightBold{")
       (t "\\ESHWeightRegular{"))
      subtrees "}"))
    (:height
     (esh--latex-export-wrapped-if val
       "\\textscale{%0.2g}{" subtrees "}"))
    (:slant
     (esh--latex-export-wrapped
      (pcase val
        (`italic "\\ESHSlantItalic{")
        (`oblique "\\ESHSlantOblique{")
        (`normal "\\ESHSlantNormal{"))
      subtrees "}"))
    (:underline
     (esh--latex-export-wrapped
      (pcase val
        (`(,color . ,type)
         ;; There are subtle spacing issues with \\ESHUnder, so don't
         ;; use it unless the underline needs to be colored.
         (let* ((prefix (if color "\\ESHUnder" "\\u"))
                (command (format "%s%S" prefix type))
                (arg (if color (format "{\\color[HTML]{%s}}" color) "")))
           (format "%s%s{" command arg))))
      subtrees "}"))
    (:box
     (esh--latex-export-wrapped
      (pcase val
        (`(,line-width ,color ,style)
         (unless (eq style nil)
           (error "Unsupported box style %S" style))
         (format "\\ESHBox{%s}{%.2fpt}{" (or color ".") (abs line-width)))
        (_ (error "Unexpected box %S" val)))
      subtrees "}"))
    (`display
     (pcase val
       (`(raise ,amount)
        (esh--latex-export-wrapped-if amount
          "\\ESHRaise{%.2f}{" subtrees "}"))
       ((pred stringp)
        (insert (esh--escape-for-latex val)))
       (_ (error "Unexpected display property %S" val))))
    (`invisible)
    (`line-height
     (unless (floatp val)
       (error "Unexpected line-height property %S" val))
     (esh--latex-export-wrapped-if val
       "\\ESHStrut{%.2g}" subtrees ""))
    (`esh--newline
     ;; Add an mbox to prevent TeX from complaining about underfull boxes.
     (esh--latex-export-wrapped-if (eq (cdr val) 'empty)
       "\\mbox{}" subtrees ""))
    (`esh--break (mapc #'esh--latex-export-tree subtrees))
    (_ (error "Unexpected property %S" property))))

(defun esh--latex-export-tree (tree)
  "Export a single TREE to LaTeX."
  (pcase tree
    (`(text ,start ,end)
     (esh--latex-export-text-node start end))
    (`(tag (,property . ,val) . ,trees)
     (esh--latex-export-tag-node property val trees))))

(defun esh--latex-export-trees (source-buf trees)
  "Export TREES to LaTeX.
SOURCE-BUF is the buffer that TEXT nodes point to."
  (let ((esh--latex-source-buffer-for-export source-buf))
    (mapc #'esh--latex-export-tree trees)))

(defun esh--latexify-protect-bols ()
  "Prefix each line of current buffer with a call to \\ESHBol{}.
This used to only be needed for lines starting with whitespace,
but leading dashes sometimes behave strangely; it's simpler (and
safer) to prefix all lines.  \\ESHBol is a no-op in inline mode."
  (goto-char (point-min))
  (while (re-search-forward "^" nil t)
    (replace-match "\\ESHBol{}" t t)))

(defun esh--latexify-protect-eols ()
  "Suffix each line of current buffer with a call to \\ESHEol.
Do this instead of using catcodes, for robustness.  Including a
brace pair after \\ESHEol would break alignment of continuation
lines in inline blocks."
  (goto-char (point-min))
  (while (search-forward "\n" nil t)
    (replace-match "\\ESHEol\n" t t)))

(defun esh--latex-export-buffer ()
  "Export current buffer to LaTeX."
  (let ((inhibit-modification-hooks t))
    (setq-local buffer-undo-list t)
    (untabify (point-min) (point-max))
    (esh--commit-overlays (current-buffer))
    (esh--remove-final-newline)
    (esh--commit-compositions)
    (esh--mark-newlines '(esh--break t)))
  (let ((source-buf (current-buffer))
        (trees (let ((esh-interval-tree-nest-annotations t))
                 (esh--buffer-to-property-trees
                  esh--latex-props
                  esh--latex-face-attrs
                  esh--latex-priorities
                  #'esh--latex-range-filter))))
    (with-temp-buffer
      (esh--latex-export-trees source-buf trees)
      (esh--latexify-protect-eols)
      (esh--latexify-protect-bols)
      (buffer-string))))

(defun esh--latexify-insert-preamble ()
  "Read ESH's LaTeX preamble from disk and insert it at point."
  (insert-file-contents (expand-file-name "etc/esh-preamble.tex" esh--directory)))

(defvar esh--latexify-preamble-marker "^%%[ \t]*ESH-preamble-here[ \t]*$")

(defun esh--latexify-add-preamble ()
  "Expand `esh--latexify-preamble-marker', if present."
  (goto-char (point-min))
  (when (re-search-forward esh--latexify-preamble-marker nil t)
    (delete-region (match-beginning 0) (match-end 0))
    (esh--latexify-insert-preamble)))

(defconst esh--latex-block-begin
  (concat "^[ \t]*%%[ \t]*\\(ESH\\(?:\\(?:Inline\\)?Block\\)?\\)\\b\\([^:]*\\): \\([^ \t\n]+\\)[ \t]*\n"
          "[ \t]*\\\\begin{\\(.+?\\)}.*\n"))

(defconst esh--latex-block-end
  "\n[ \t]*\\\\end{%s}")

(defun esh--latex-match-block ()
  "Find the next ESH block, if any."
  (when (re-search-forward esh--latex-block-begin nil t)
    (let* ((beg (match-beginning 0))
           (code-beg (match-end 0))
           (block-type (match-string-no-properties 1))
           (block-opts (match-string-no-properties 2))
           (mode (match-string-no-properties 3))
           (env (match-string-no-properties 4))
           (end-re (format esh--latex-block-end (regexp-quote env))))
      (when (string= "" mode)
        (error "Invalid ESH header: %S" (match-string-no-properties 0)))
      (when (re-search-forward end-re nil t)
        (let* ((code-end (match-beginning 0))
               (code (buffer-substring-no-properties code-beg code-end)))
          (list block-type mode block-opts code beg (match-end 0)))))))

(defun esh--latexify-inline-verb-matcher (re)
  "Search for a \\verb-like delimiter from point.
That is, a match of the form RE?...? where ? is any
character."
  (when (and re (re-search-forward re nil t))
    (let ((form-beg (match-beginning 0))
          (command (match-string 0))
          (delimiter (char-after))
          (code-beg (1+ (point))))
      (unless delimiter
        (error "No delimiter found after use of `%s'" command))
      (goto-char code-beg)
      (if (search-forward (char-to-string delimiter) (point-at-eol) t)
          (list form-beg (point) code-beg (1- (point)) command)
        (error "No matching delimiter found after use of `%s%c'"
               command delimiter)))))

(defun esh--latexify-beginning-of-document ()
  "Go past \\begin{document}."
  (goto-char (point-min))
  (unless (search-forward "\\begin{document}" nil t)
    (goto-char (point-min))))

(defvar esh-latex-inline-macro-alist nil
  "Alist of inline ESH marker → mode function.

This list maps inline verb-like markers to modes.  For example,
it could contain (\"@ocaml \\\\verb\" . tuareg-mode) to recognize
all instances of “@ocaml \\verb|...|” as OCaml code to be
highlighted with `tuareg-mode'.  This list is ignored in HTML
mode.  See the manual for more information.")

(defun esh-latex-add-inline-verb (verb mode)
  "Teach ESH about an inline VERB, highlighted with MODE.
For example (esh-latex-add-inline-verb \"\\\\ocaml\" \\='tuareg-mode)
recognizes all instances of “\\ocaml|...|” as OCaml code to be
highlighted with `tuareg-mode'."
  (add-to-list 'esh-latex-inline-macro-alist (cons verb mode)))

(defconst esh--latexify-inline-template "\\ESHInline{%s}")
(defconst esh--latexify-block-template "\\begin{ESHBlock}%s\n%s\n\\end{ESHBlock}")
(defconst esh--latexify-inline-block-template "\\begin{ESHInlineBlock}%s\n%s\n\\end{ESHInlineBlock}")

(defvar esh--latex-pv
  "Whether to build and dump a table of highlighted inline code.")

(defvar-local esh--latex-pv-highlighting-map nil
  "List of (macro VERB CODE TEX) lists.
Each entry corresponds to one code snippet CODE, introduced by
\\VERB, and highlighted into TEX.")

(defun esh--latex-pv-record-snippet (verb code tex)
  "Record highlighting of VERB|CODE| as TEX."
  (when esh--latex-pv
    (unless (string-match "\\\\\\([a-zA-Z]+\\)" verb)
      (error "%S isn't compatible with --precompute-verbs-map.
To work reliably, ESH-pv verb macros must be in the form \\[a-zA-Z]+" verb))
    (push (list 'macro (match-string 1 verb) code tex)
          esh--latex-pv-highlighting-map)))

(defconst esh--latex-pv-delimiters
  (mapcar (lambda (c)
            (cons c (regexp-quote (char-to-string c))))
          (string-to-list "|`/!=~+-,;:abcdefghijklmnopqrstuvwxyz"))
  "Alist of character → regexp matching that character.")

(defun esh--latex-pv-find-delimiter (code)
  "Find a delimiter that does not appear in CODE."
  (let ((candidates esh--latex-pv-delimiters)
        (delim nil))
    (while (not delim)
      (unless candidates
        (error "No delimiter found to wrap %S" code))
      (pcase-let* ((`(,char . ,re) (pop candidates)))
        (when (not (string-match-p re code))
          (setq delim char))))
    delim))

(defconst esh--latex-pv-def-template "\\DeclareRobustCommand*{\\%s}{\\ESHpvLookupVerb{%s}}\n")
(defconst esh--latex-pv-push-template "\\ESHpvDefineVerb{%s}%c%s%c{%s}\n")

(defun esh--latex-pv-export-macro (verb code tex decls)
  "Insert an \\ESHpvDefine form for (macro VERB CODE TEX).
DECLS accumulates existing declarations."
  (let* ((dl (esh--latex-pv-find-delimiter code))
         (decl (format esh--latex-pv-push-template verb dl code dl tex)))
    (unless (gethash decl decls) ;; Remove duplicates
      (puthash decl t decls)
      (insert decl))))

(defun esh--latex-pv-export-latex (map)
  "Prepare \\ESHpvDefine forms for all records in MAP.
Records must match the format of `esh--latex-pv-highlighting-map'."
  (with-temp-buffer
    (let ((verbs (make-hash-table :test #'equal))
          (decls (make-hash-table :test #'equal)))
      (pcase-dolist (`(macro ,verb ,code ,tex) map)
        (puthash verb t verbs)
        (esh--latex-pv-export-macro verb code tex decls))
      (maphash (lambda (verb _)
                 (insert (format esh--latex-pv-def-template verb verb)))
               verbs))
    (buffer-string)))

(defun esh--latexify-do-inline-macros ()
  "Latexify sources in ESH inline macros."
  (let* ((modes-alist esh-latex-inline-macro-alist)
         (envs-re (when modes-alist (regexp-opt (mapcar #'car modes-alist)))))
    (esh--latexify-beginning-of-document)
    (let ((match-info nil))
      (while (setq match-info (esh--latexify-inline-verb-matcher envs-re))
        (pcase match-info
          (`(,beg ,end ,code-beg ,code-end ,cmd)
           (let* ((mode-fn (cdr (assoc cmd modes-alist)))
                  (code (buffer-substring-no-properties code-beg code-end))
                  (tex (esh--export-str code mode-fn #'esh--latex-export-buffer))
                  (wrapped (format esh--latexify-inline-template tex)))
             (goto-char beg)
             (delete-region beg end)
             (esh--latex-pv-record-snippet cmd code wrapped)
             (insert wrapped))))))))

(defconst esh--latex-block-templates
  `(("ESH" . ,esh--latexify-block-template)
    ("ESHBlock" . ,esh--latexify-block-template)
    ("ESHInlineBlock" . ,esh--latexify-inline-block-template)))

(defun esh--latexify-do-block-envs ()
  "Latexify sources in esh block environments."
  (goto-char (point-min))
  (let ((match nil))
    (while (setq match (esh--latex-match-block))
      (pcase-let* ((`(,block-type ,mode-str ,block-opts ,code ,beg ,end) match)
                   (mode-fn (esh--resolve-mode-fn mode-str))
                   (template (cdr (assoc block-type esh--latex-block-templates))))
        (delete-region beg end)
        (let* ((tex (esh--export-str code mode-fn #'esh--latex-export-buffer))
               (wrapped (format template block-opts tex)))
          (insert wrapped))))))

(defun esh2tex-current-buffer ()
  "Fontify contents of all ESH environments.
Replace the ESH-Latexify sources in environments delimited by
`esh-latexify-block-envs' and user-defined inline groups."
  (interactive)
  (save-excursion
    (unwind-protect
        (progn
          (esh--latexify-add-preamble)
          (esh--latexify-do-inline-macros)
          (esh--latexify-do-block-envs))
      (esh--kill-temp-buffers))))

(defun esh2tex-tex-file (path)
  "Fontify contents of all ESH environments in PATH."
  (with-temp-buffer
    (esh--insert-file-contents path)
    (esh2tex-current-buffer)
    (buffer-string)))

(defun esh2tex-tex-file-pv (path)
  "Find and highlight inline ESH macros in PATH.
Return a document consisting of “snippet → highlighted
code” pairs (in \\ESHpvDefine form)."
  (let ((esh--latex-pv t))
    (with-temp-buffer
      (esh--insert-file-contents path)
      (esh2tex-current-buffer)
      (esh--latex-pv-export-latex esh--latex-pv-highlighting-map))))

(defun esh2tex-source-file (source-path)
  "Fontify contents of SOURCE-PATH.
Return result as a LaTeX string."
  (esh--export-file source-path #'esh--latex-export-buffer))

;;; Producing HTML

(defconst esh--html-specials '((?< . "&lt;")
                            (?> . "&gt;")
                            (?& . "&amp;")
                            (?\" . "&quot;")))

(defconst esh--html-specials-re
  (regexp-opt-charset (mapcar #'car esh--html-specials)))

(defun esh--html-substitute-special (m)
  "Get replacement for HTML special M."
  (cdr (assq (aref m 0) esh--html-specials)))

(defun esh--html-substitute-specials (str)
  "Escape HTML specials in STR."
  (replace-regexp-in-string
   esh--html-specials-re #'esh--html-substitute-special str t t))

(defconst esh--html-void-tags '(area base br col embed hr img input
                                  link menuitem meta param source track wbr))

(defun esh--html-serialize (node escape-specials)
  "Write NODE as HTML string to current buffer.
With non-nil ESCAPE-SPECIALS, quote special HTML characters in
NODE's body.  If ESCAPE-SPECIALS is nil, NODE must be a string."
  (pcase node
    ((pred stringp)
     (insert (if escape-specials
                 (esh--html-substitute-specials node)
               node)))
    (`(comment nil ,comment)
     ;; "--" isn't allowed in comments, so no need for escaping
     (insert "<!--" comment "-->"))
    (`(,tag ,attributes . ,children)
     (unless escape-specials
       (error "Must escape specials in %S" tag))
     (let ((tag-name (symbol-name tag))
           (escape-specials (not (memq tag '(script style)))))
       (insert "<" tag-name)
       (pcase-dolist (`(,attr . ,val) attributes)
         (insert " " (symbol-name attr) "=\"")
         (esh--html-serialize val escape-specials)
         (insert "\""))
       (if (memq tag esh--html-void-tags)
           (insert " />")
         (insert ">")
         (dolist (c children)
           (esh--html-serialize c escape-specials))
         (insert "</" tag-name ">"))))
    (_ (error "Unprintable node %S" node))))

(defconst esh--html-props
  '(display invisible non-ascii line-height esh--newline))
(defconst esh--html-face-attrs
  '(:underline :background :foreground :weight :slant :box :height))

(defconst esh--html-priorities
  `( ;; Fine to split
    ,@'(line-height :underline :foreground :weight :height :background)
    ;; Should not split
    ,@'(:slant :box display esh--newline non-ascii invisible))
  "Priority order for text properties in HTML export.
See `esh--resolve-event-conflicts'.")

(defun esh--html-range-filter (range)
  "Remove incorrectly placed line-height properties of RANGE."
  (let ((alist (cl-caddr range)))
    (when (and (assq 'line-height range)
               (not (assq 'esh--newline range)))
      (setf (cl-caddr range) (assq-delete-all 'line-height alist)))))

(defun esh--html-wrap-children (styles non-ascii children &optional tag)
  "Apply STYLES and NON-ASCII markup to CHILDREN.
STYLES are applied using a new TAG node."
  (when non-ascii ;; Aligning wide characters properly requires 3 nested spans
    (setq children `((span nil (span nil ,@children)))))
  (if (or styles non-ascii tag)
      (let ((style (mapconcat (lambda (p) (concat (car p) ":" (cdr p))) styles ";")))
        `((,(or tag 'span) (,@(when styles `((style . ,style)))
                            ,@(when non-ascii `((class . "esh-non-ascii"))))
           ,@children)))
    children))

(defun esh--html-export-tag-node (attributes children &optional tag)
  "Wrap CHILDREN in a HTML implementation of ATTRIBUTES.
Return an HTML AST; the root is a TAG node (default: span)."
  (let ((styles nil)
        (raised nil)
        (non-ascii nil)
        (line-height nil))
    (pcase-dolist (`(,property . ,val) attributes)
      (when val
        (pcase property
          (:foreground
           (push (cons "color" (concat "#" val)) styles))
          (:background
           (push (cons "background-color" (concat "#" val)) styles))
          (:weight
           (push (cons "font-weight" (format "%d" val)) styles))
          (:height
           (push (cons "font-size" (format "%d%%" (* val 100))) styles))
          (:slant
           (push (cons "font-style" (symbol-name val)) styles))
          (:underline
           (pcase-let ((`(,color . ,type) val))
             (push (cons "text-decoration" "underline") styles)
             (when (eq type 'wave)
               (push (cons "text-decoration-style" "wavy") styles))
             (when color
               (push (cons "text-decoration-color" (concat "#" color))
                     styles))))
          (:box
           (pcase-let ((`(,line-width ,color ,style) val))
             (unless (eq style nil)
               (error "Unsupported box style %S" style))
             (let ((box-style `(,(format "%dpt" (abs line-width))
                                ,(pcase style
                                   (`released-button "outset")
                                   (`pressed-button "inset")
                                   (_ "solid"))
                                ,@(when color `(,color)))))
               (push (cons "border" (esh--join box-style " ")) styles))))
          (`display
           (pcase val
             (`(raise ,amount)
              (setq raised t)
              (push (cons "bottom" (format "%2gem" amount)) styles))
             ((pred stringp)
              (setq children (list val)))
             (_ (error "Unexpected display property %S" val))))
          (`invisible
           (when val (setq children nil)))
          (`line-height
           (unless (floatp val)
             (error "Unexpected line-height property %S" val))
           (setq line-height (format "%.2g" val)))
          (`non-ascii
           (when val (setq non-ascii t)))
          (`esh--newline)
          (_ (error "Unexpected property %S" property)))))
    (cond
     ((null children) nil)
     (raised
      `((,(or tag 'span) ((class . "esh-raised"))
         (span ((class . "esh-raised-contents"))
               ,@(esh--html-wrap-children styles non-ascii children))
         (span ((class . "esh-raised-placeholder"))
               ,@(esh--html-wrap-children nil non-ascii children)))))
     (line-height
      ;; CSS line-height property shouldn't cover newlines
      (nconc (esh--html-wrap-children `(("line-height" . ,line-height)) nil nil)
             (esh--html-wrap-children styles non-ascii children tag)))
     (t
      (esh--html-wrap-children styles non-ascii children tag)))))

(defun esh--html-export-tree (tree)
  "Export a single TREE to HTML."
  (pcase tree
    (`(text ,start ,end)
     (list (buffer-substring-no-properties start end)))
    (`(tag ,attributes . ,trees)
     (esh--html-export-tag-node attributes (esh--html-export-trees trees)))))

(defun esh--html-export-trees (trees)
  "Export TREES to HTML."
  (mapcan #'esh--html-export-tree trees))

(defun esh--html-export-buffer ()
  "Export current buffer to HTML AST.
This may modify to the current buffer."
  (let ((inhibit-modification-hooks t))
    (setq-local buffer-undo-list t)
    (untabify (point-min) (point-max))
    (esh--commit-overlays (current-buffer))
    (esh--remove-final-newline)
    (esh--commit-compositions)
    (esh--mark-newlines)
    (esh--mark-non-ascii))
  (let ((trees (let ((esh-interval-tree-nest-annotations nil))
                 (esh--buffer-to-property-trees
                  esh--html-props
                  esh--html-face-attrs
                  esh--html-priorities
                  #'esh--html-range-filter))))
    (esh--html-export-trees trees)))

(defvar esh--html-src-class-prefix "src-"
  "HTML class prefix indicating a fontifiable tag.")

(defvar esh--html-src-class-re nil
  "Regexp matching classes of tags to be processed by ESH.
Dynamically set.")

(defvar esh-html-default-languages-alist nil
  "Alist of tag → language string.
For example, (code . \"emacs-lisp\") would highlight all `code'
tags with no ESH attribute as Emacs Lisp.")

(defun esh--htmlify-guess-lang (tag attributes)
  "Guess highlighting language based on TAG and ATTRIBUTES."
  (or (let ((class (cdr (assq 'class attributes))))
        (when (and class (string-match esh--html-src-class-re class))
          (match-string 1 class)))
      (cdr (assq tag esh-html-default-languages-alist))))

(defun esh--htmlify-do-tree (node)
  "Highlight code in annotated descendants of NODE."
  (pcase node
    ((pred stringp) node)
    (`(,tag ,attributes . ,children)
     (let ((lang (esh--htmlify-guess-lang tag attributes)))
       (if lang
           (let* ((mode-fn (esh--resolve-mode-fn lang))
                  (code (car children)))
             (unless (and (stringp code) (null (cdr children)))
               (error "Code block has children: %S" node))
             `(,tag ,attributes
                    ,@(esh--export-str code mode-fn #'esh--html-export-buffer)))
         `(,tag ,attributes
                ,@(mapcar (lambda (c) (esh--htmlify-do-tree c)) children)))))))

(defvar esh-html-before-parse-hook nil
  "Hook called before parsing input HTML.
Hook may e.g. make modifications to the buffer.")

(defun esh--html-read-tag (tag)
  "Read HTML TAG at point in current buffer."
  (when (looking-at (format "<%s [^>]+>" (regexp-quote tag)))
    (goto-char (match-end 0))
    (skip-chars-forward " \n\t")
    (buffer-substring-no-properties (match-beginning 0) (point))))

(defun esh--html-parse-buffer ()
  "Parse HTML document in current buffer."
  (run-hook-with-args 'esh-html-before-parse-hook)
  (goto-char (point-min))
  (let* ((xml-decl (esh--html-read-tag "?xml"))
         (doctype (esh--html-read-tag "!doctype"))
         (tree (libxml-parse-html-region (point) (point-max))))
    (list xml-decl doctype tree)))

(defun esh--html-parse-file (path)
  "Parse HTML file PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (esh--html-parse-buffer)))

(defun esh--html-prepare-html-output (&rest tags)
  "Clear current buffer and insert TAGS not handled by libxml."
  (erase-buffer)
  (dolist (tag tags)
    (when tag (insert tag))))

(defun esh2html-current-buffer ()
  "Fontify contents of all ESH blocks in current document.
Highlight sources in any environments containing a class matching
`esh--html-src-class-prefix', such as `src-c', `src-ocaml', etc."
  (interactive)
  (unwind-protect
      (pcase-let* ((`(,xml-decl ,doctype ,tree) (esh--html-parse-buffer))
                   (esh--html-src-class-re (format "\\_<%s\\([^ ]+\\)\\_>"
                                                esh--html-src-class-prefix)))
        (esh--html-prepare-html-output xml-decl doctype)
        (esh--html-serialize (esh--htmlify-do-tree tree) t))
    (esh--kill-temp-buffers)))

(defun esh2html-html-file (path)
  "Fontify contents of all ESH environments in PATH."
  (with-temp-buffer
    (esh--insert-file-contents path)
    (esh2html-current-buffer)
    (buffer-string)))

;; Exporting a full buffer to HTML (htmlfontify-style)

(defvar esh--html-template-path
  (expand-file-name "etc/esh-standalone-template.html" esh--directory)
  "Path to ESH template for exporting standalone documents.")

(defun esh--html-substitute (ast substitutions)
  "Replace (FROM . TO) pairs from SUBSTITUTIONS in AST."
  (pcase ast
    ((pred stringp) ast)
    (`(,tag ,attrs . ,children)
     (or (cdr (assq tag substitutions))
         (let* ((subst-fun (lambda (c) (esh--html-substitute c substitutions)))
                (children (mapcar subst-fun children)))
           `(,tag ,attrs . ,children))))))

(defun esh--html-wrap-in-body-tag (children)
  "Wrap CHILDREN in <body> and <pre> tags."
  (let* ((attrs (esh--extract-face-attributes esh--html-face-attrs '(default)))
         (normalized (esh--tree-map-attrs-1 #'esh--normalize-defaults attrs))
         (pre `((pre ((class . "esh-standalone")) ,@children))))
    (esh--html-export-tag-node normalized pre 'body)))

(defun esh--html-export-wrapped-1 ()
  "Render the current buffer as an HTML AST wrapped in a body tag."
  (esh--with-copy-of-current-buffer
    (car (esh--html-wrap-in-body-tag (esh--html-export-buffer)))))

(defun esh--html-export-wrapped ()
  "Render the current buffer as an HTML AST.
Unlike `esh--html-export-buffer', this produces a complete
webpage: the result of exporting is inserted into a template
found at `esh--html-template-path'.  Returns a 3-elements
list: (XML-HEADER DOCTYPE AST)."
  (pcase-let* ((body (esh--html-export-wrapped-1))
               (title (format "ESH: %s" (buffer-name)))
               (`(,xml ,dt ,template) (esh--html-parse-file esh--html-template-path))
               (substitutions `((esh-title . ,title) (esh-body . ,body)))
               (document (esh--html-substitute template substitutions)))
    (list xml dt document)))

(defun esh-htmlfontify-buffer ()
  "Render the current buffer as a webpage."
  (interactive)
  (pcase-let* ((`(,xml ,dt ,document) (esh--html-export-wrapped))
               (out-buf-name (format "*esh-htmlfontify: %s*" (buffer-name))))
    (with-current-buffer (generate-new-buffer out-buf-name)
      (esh--html-prepare-html-output xml dt)
      (esh--html-serialize document t)
      (html-mode)
      (pop-to-buffer (current-buffer)))))

(defun esh--htmlfontify-to-string ()
  "Render the current buffer as a webpage.
Returns HTML source code as a string."
  (pcase-let* ((`(,xml ,dt ,document) (esh--html-export-wrapped)))
    (with-temp-buffer
      (esh--html-prepare-html-output xml dt)
      (esh--html-serialize document t)
      (buffer-string))))

(defun esh2html-source-file (source-path)
  "Fontify contents of SOURCE-PATH.
Return result as a LaTeX string."
  (esh--export-file source-path #'esh--htmlfontify-to-string))

(provide 'esh)
;;; esh.el ends here

;; Local Variables:
;; checkdoc-arguments-in-order-flag: nil
;; End:
