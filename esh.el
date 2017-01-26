;;; esh.el --- Use Emacs to highlight code snippets in LaTeX documents  -*- lexical-binding: t; -*-

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

;; ESH is a replacement for lstlistings, minted, etc.\ that uses Emacs'
;; major-modes to syntax-highlight code blocks in LaTeX documents.
;;
;; See URL `https://github.com/cpitclaudel/esh2tex' for usage instructions.

;;; Code:

;; Can't depend on external packages
(require 'color)
(require 'cl-lib) ;; cl-assert
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

(defun esh--normalize-color (color)
  "Return COLOR as a hex string."
  (unless (member color '("unspecified-fg" "unspecified-bg" "" nil))
    (let ((color (if (= (aref color 0) ?#) color
                   (apply #'color-rgb-to-hex (color-name-to-rgb color)))))
      (substring (upcase color) 1))))

(defun esh--normalize-color-unless (color attr)
  "Return COLOR as a hex string.
If COLOR matches value of ATTR in default face, return
nil instead."
  (let ((val (esh--normalize-color color))
        (attr-default (face-attribute 'default attr)))
    (unless (and attr (equal val (esh--normalize-color attr-default)))
      val)))

(defun esh--filter-cdr (val alist)
  "Remove conses in ALIST whose `cdr' is VAL."
  ;; FIXME phase this out once Emacs 25 is everywhere
  (let ((kept nil))
    (while alist
      (let ((top (pop alist)))
        (when (not (eq (cdr top) val))
          (push top kept))))
    (nreverse kept)))

(defun esh--append-dedup (&rest seqs)
  "Concatenate SEQS, remove duplicates (wrt `eq') on the way."
  (let ((deduped nil))
    (while seqs
      (let ((seq (pop seqs)))
        (while seq
          (let ((elem (pop seq)))
            (unless (memq elem deduped)
              (push elem deduped))))))
    (nreverse deduped)))

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
  "Remove last newline of current buffer, if present."
  (goto-char (point-max))
  ;; There may not be a final newline in standalone mode
  (when (eq (char-before) ?\n)
    (delete-char -1)))

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

;;; Segmenting a buffer

(defun esh--buffer-ranges-from (start prop)
  "Create a stream of buffer ranges from START.
Ranges are pairs of START..END positions in which all characters
have the same value of PROP or, if PROP is nil, of all
properties."
  (let ((ranges nil)
        (making-progress t))
    (while making-progress
      (let ((end (if prop (next-single-char-property-change start prop)
                   (next-char-property-change start))))
        (if (< start end)
            (push (cons start end) ranges)
          (setq making-progress nil))
        (setq start end)))
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
  (mapcar (lambda (prop)
            (cons prop (get-char-property pos prop)))
          props))

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
  ;; `get-char-property' returns either overlay properties (if any), or text
  ;; properties — never both.  Hence the two lists (and the deduplication, since
  ;; otherwise relative font sizes get squared).
  (esh--append-dedup (esh--as-list (get-text-property pos 'face))
                  (esh--as-list (get-char-property pos 'face))))

;; Caching this function speeds things up by about 5%
(defun esh--extract-face-attributes-1 (face-attributes faces)
  "Extract FACE-ATTRIBUTES from FACES."
  (mapcar (lambda (attr) (cons attr (esh--faces-attribute faces attr)))
          face-attributes))

(defun esh--extract-face-attributes (face-attributes pos)
  "Extract FACE-ATTRIBUTES from POS."
  (let ((faces (esh--faces-at-point pos)))
    (and faces ;; Empty list of faces → no face attributes
         (esh--extract-face-attributes-1 face-attributes faces))))

;;; Massaging properties

(defun esh--commit-compositions ()
  "Apply compositions in current buffer.
This replaced each composed string by its composition, forgetting
the original string."
  (let ((composed-ranges (esh--buffer-ranges 'composition)))
    (dolist (pair (reverse composed-ranges))
      (pcase pair
        (`(,from . ,to)
         (let ((composition (get-char-property from 'composition))
               (char nil))
           (pcase composition
             (`((,_ . ,c))
              (setq char c))
             (`(,_ ,_ ,vc) ;; No support for ,[] QPatterns in 24.5
              (when (and (vectorp vc) (= (length vc) 1))
                (setq char (aref vc 0)))))
           (when char
             (goto-char from)
             (let ((props (text-properties-at from)))
               (delete-region from to)
               (insert char)
               (set-text-properties from (1+ from) props)
               (remove-text-properties from (1+ from) '(composition))))))))))

(defun esh--mark-newlines ()
  "Add a `newline' text property to each \\n character.
The value is either `empty' or `non-empty' (we need this to add a
dummy element on empty lines to prevent LaTeX from complaining
about underful hboxes).  Adding these properties also make it
easy to group ranges by line, which yields a significant speedup
when processing long files (compared to putting all lines in one
large interval tree)."
  (goto-char (point-min))
  (while (search-forward "\n" nil t)
    (set-text-properties
     (match-beginning 0) (match-end 0)
     `(newline
       ,(cons (point) ;; Prevent merging of equal properties
              ;; (point-at-bol 0) is beginning of previous line
              ;; (match-beginning 0) is end of previous line
              (if (eq (point-at-bol 0) (match-beginning 0))
                  'empty 'non-empty))))))

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
             (attrs-alist (esh--extract-face-attributes face-attrs start))
             (merged-alist (nconc (esh--filter-cdr 'unspecified attrs-alist)
                                  (esh--filter-cdr nil props-alist))))
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
      (dolist (prop props)
        (let ((old (assq prop prev-alist))
              (new (assq prop alist)))
          (unless (equal (cdr old) (cdr new))
            (when old
              (push `(close ,start ,old) events))
            (when new
              (push `(open ,start ,new) events)))))
      (setq prev-end end)
      (setq prev-alist alist))
    (dolist (pair prev-alist)
      (push `(close ,prev-end ,pair) events))
    (nreverse events)))

(defun esh--event-property (event)
  "Read property changed by EVENT."
  (car (nth 2 event)))

(defun esh--group-ranges-by-line-rev (ranges)
  "Group RANGES by line.
Return a list (in reverse order of buffer position); each element
is a list (BOL EOL RANGES)."
  (let ((lines nil)
        (cur-line nil)
        (cur-bol (point-min)))
    (dolist (range ranges)
      (push range cur-line)
      ;; Newlines are marked with a single property, `newline'
      (when (eq 'newline (caar (cl-caddr range)))
        (let ((end (cadr range)))
          (push `(,cur-bol ,end ,(nreverse cur-line)) lines)
          (setq cur-line nil cur-bol end))))
    (push `(,cur-bol ,(point-max) ,(nreverse cur-line)) lines)
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
         (cl-assert (equal annot (cddr (car (gethash (car annot) ints-tbl)))) t)
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

(defun esh--buffer-to-property-trees (text-props face-attrs priority-ranking)
  "Construct a properly nesting list of event from current buffer.
TEXT-PROPS and FACE-ATTRS specify which properties to keep track
of.  PRIORITY-RANKING ranks all these properties in order of
tolerance to splitting (if a property comes late in this list,
ESH will try to preserve this property's spans when resolving
conflicts).  Splitting is needed because in Emacs text properties
can overlap in ways that are not representable as a tree.
Result is influenced by `esh-interval-tree-nest-annotations'."
  (let* ((flat-tree nil)
         (ranges (esh--buffer-ranges))
         (ann-ranges (esh--annotate-ranges ranges text-props face-attrs)))
    (pcase-dolist (`(,bol ,eol ,ranges) (esh--group-ranges-by-line-rev ann-ranges))
      (let* ((events (esh--ranges-to-events ranges priority-ranking))
             (intervals (esh--events-to-intervals events priority-ranking))
             (tree (esh--intervals-to-tree intervals bol eol)))
        (setq flat-tree (esh-interval-tree-flatten-acc tree flat-tree))))
    flat-tree))

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

;;; Producing LaTeX

(defconst esh--latex-props '(display invisible line-height newline))
(defconst esh--latex-face-attrs '(:underline :background :foreground :weight :slant :box :height))

(defconst esh--latex-priorities
  `(,@'(line-height newline :underline :foreground :weight :height :background) ;; Fine to split
    ,@'(:slant :box display invisible)) ;; Should not split
  "Priority order for text properties in LaTeX export.
See `esh--resolve-event-conflicts'.")

(eval-and-compile
  (defvar esh--latex-specials
    ;; http://tex.stackexchange.com/questions/67997/escaped-characters-in-typewriter-font/68002#68002
    '((?$ . "\\$") (?% . "\\%") (?& . "\\&") (?{ . "\\{") (?} . "\\}") (?_ . "\\_") (?# . "\\#")
      (?` . "{`}") (?' . "{'}") (?< . "{<}") (?> . "{>}") ;; A few ligatures
      (?\\ . "\\textbackslash{}") (?^ . "\\textasciicircum{}") (?~ . "\\textasciitilde{}")
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

(defun esh--escape-for-latex (str)
  "Escape LaTeX special characters in STR."
  (esh--latex-wrap-non-ascii (esh--latex-substitute-specials str)))

(defun esh--normalize-underline (underline)
  "Normalize UNDERLINE."
  (pcase underline
    (`t '(nil . line))
    ((pred stringp) `(,underline . line))
    ((pred listp) `(,(plist-get underline :color) .
                    ,(or (plist-get underline :style) 'line)))))

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
    ((or `ultrabold `ultra-bold) 900)))

(defun esh--normalize-weight-coarse (weight)
  "Normalize WEIGHT to 3 values."
  (let ((weight (esh--normalize-weight weight)))
    (when (numberp weight)
      (cond
       ((< weight 500) 'light)
       ((> weight 500) 'bold)
       (t 'regular)))))

(defun esh--normalize-height (height)
  "Normalize HEIGHT to a relative (float) height."
  (let* ((default-height (face-attribute 'default :height))
         (height (merge-face-attribute :height height default-height)))
    (unless (eq height default-height)
      (/ height (float default-height)))))

(defun esh--normalize-box (box)
  "Normalize face attribute BOX."
  (pcase box
    (`t `(1 nil nil))
    ((pred stringp) `(1 ,box nil))
    ((pred listp) `(,(or (plist-get box :line-width) 1)
                    ,(plist-get box :color)
                    ,(plist-get box :style)))))

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
     (esh--latex-export-wrapped-if (esh--normalize-color-unless val :foreground)
       "\\textcolor[HTML]{%s}{" subtrees "}"))
    (:background
     ;; FIXME: Force all lines to have the the same height?
     ;; Could use \\vphantom{'g}\\smash{…}
     (esh--latex-export-wrapped-if (esh--normalize-color-unless val :background)
       "\\colorbox[HTML]{%s}{" subtrees "}"))
    (:weight
     (esh--latex-export-wrapped
      (pcase (esh--normalize-weight-coarse val)
        (`light "\\ESHWeightLight{")
        (`regular "\\ESHWeightRegular{")
        (`bold "\\ESHWeightBold{")
        (_ (error "Unexpected weight %S" val)))
      subtrees "}"))
    (:height
     (esh--latex-export-wrapped-if (esh--normalize-height val)
       "\\textscale{%0.2g}{" subtrees "}"))
    (:slant
     (esh--latex-export-wrapped
      (pcase val
        (`italic "\\ESHSlantItalic{")
        (`oblique "\\ESHSlantOblique{")
        (`normal "\\ESHSlantNormal{")
        (_ (error "Unexpected slant %S" val)))
      subtrees "}"))
    (:underline
     (esh--latex-export-wrapped
      (pcase (esh--normalize-underline val)
        (`(,color . ,type)
         (setq color (esh--normalize-color color))
         ;; There are subtle spacing issues with \\ESHUnder, so don't
         ;; use it unless the underline needs to be colored.
         (let* ((prefix (if color "\\ESHUnder" "\\u"))
                (command (format "%s%S" prefix type))
                (arg (if color (format "{\\color[HTML]{%s}}" color) "")))
           (format "%s%s{" command arg)))
        (_ (error "Unexpected underline %S" val)))
      subtrees "}"))
    (:box
     (esh--latex-export-wrapped
      (pcase (esh--normalize-box val)
        (`(,line-width ,color ,style)
         (setq color (esh--normalize-color color))
         (unless (eq style nil)
           (error "Unsupported box style %S" style))
         (format "\\ESHBox{%s}{%gpt}{" (or color ".") (abs line-width)))
        (_ (error "Unexpected box %S" val)))
      subtrees "}"))
    (`display
     (pcase val
       (`(raise ,amount)
        (esh--latex-export-wrapped-if amount
          "\\ESHRaise{%gex}{" subtrees "}"))
       ((pred stringp)
        (insert (esh--escape-for-latex val)))
       (_ (error "Unexpected display property %S" val))))
    (`invisible)
    (`line-height
     (unless (floatp val)
       (error "Unexpected line-height property %S" val))
     (esh--latex-export-wrapped-if val
       "\\ESHStrut{%.2g}" subtrees ""))
    (`newline
     ;; Add an mbox to prevent TeX from complaining about underfull boxes.
     (esh--latex-export-wrapped-if (eq (cdr val) 'empty)
       "\\mbox{}" subtrees ""))
    (_ (error "Unexpected property %S" property))))

(defun esh--latex-export-tree (tree)
  "Export a single TREE to LaTeX."
  (pcase tree
    (`(text ,start ,end)
     (esh--latex-export-text-node start end))
    (`(tag (,property . ,val) . ,trees)
     (esh--latex-export-tag-node property val trees))))

(defun esh--latex-export (source-buf trees)
  "Export TREES to LaTeX.
SOURCE-BUF is the buffer that TEXT nodes point to."
  (let ((esh--latex-source-buffer-for-export source-buf))
    (mapc #'esh--latex-export-tree trees)))

(defun esh--latex-exporter (source-buf)
  "Specialize `esh--latex-export-tree' to SOURCE-BUF."
  (apply-partially #'esh--latex-export-tree source-buf))

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

(defun esh--latexify-current-buffer ()
  "Export current buffer to LaTeX."
  (let ((inhibit-modification-hooks t))
    (esh--remove-final-newline)
    (esh--commit-compositions)
    (esh--mark-newlines))
  (let ((source-buf (current-buffer))
        (trees (let ((esh-interval-tree-nest-annotations t))
                 (esh--buffer-to-property-trees
                  esh--latex-props
                  esh--latex-face-attrs
                  esh--latex-priorities))))
    (with-temp-buffer
      (esh--latex-export source-buf trees)
      (esh--latexify-protect-eols)
      (esh--latexify-protect-bols)
      (buffer-string))))

(defun esh--latexify-insert-preamble ()
  "Read ESH's LaTeX preamble from disk and insert it at point."
  (insert-file-contents (expand-file-name "esh-preamble.tex" esh--directory)))

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
                  (tex (esh--export-str code mode-fn #'esh--latexify-current-buffer))
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
        (let* ((tex (esh--export-str code mode-fn #'esh--latexify-current-buffer))
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
  (let ((mode-fn (esh--find-auto-mode source-path)))
    (with-current-buffer (esh--make-temp-buffer mode-fn)
      (esh--insert-file-contents source-path)
      (esh--export-buffer #'esh--latexify-current-buffer))))

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

(defun esh--htmlify-serialize (node escape-specials)
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
         (esh--htmlify-serialize val escape-specials)
         (insert "\""))
       (if (memq tag esh--html-void-tags)
           (insert " />")
         (insert ">")
         (dolist (c children)
           (esh--htmlify-serialize c escape-specials))
         (insert "</" tag-name ">"))))
    (_ (error "Unprintable node %S" node))))

(defconst esh--html-props '(display invisible non-ascii newline))
(defconst esh--html-face-attrs '(:underline :background :foreground :weight :slant)) ;; TODO :height :line-height :box

(defconst esh--html-priorities
  `(,@'(line-height newline :underline :foreground :weight :height :background) ;; Fine to split
    ,@'(:slant :box display non-ascii invisible)) ;; Should not split
  "Priority order for text properties in HTML export.
See `esh--resolve-event-conflicts'.")

(defun esh--html-export-tag-node (attributes subtrees)
  "Export SUBTREES wrapped in a HTML implementation of ATTRIBUTES."
  (let ((styles nil)
        (raised nil)
        (non-ascii nil)
        (children (esh--html-export subtrees)))
    (pcase-dolist (`(,property . ,val) attributes)
      (when val
        (pcase property
          (:foreground
           (when (setq val (esh--normalize-color-unless val :foreground))
             (push (concat "color: #" val) styles)))
          (:background
           (when (setq val (esh--normalize-color-unless val :background))
             (push (concat "background-color: #" val) styles)))
          (:weight
           (if (setq val (esh--normalize-weight val))
               (push (format "font-weight: %d" val) styles)
             (error "Unexpected weight %S" val)))
          (:slant
           (if (memq val '(italic oblique normal))
               (push (concat "font-style: " (symbol-name val)) styles)
             (error "Unexpected slant %S" val)))
          (:underline
           (pcase (esh--normalize-underline val)
             (`(,color . ,type)
              (push "text-decoration: underline" styles)
              (when (eq type 'wave)
                (push "text-decoration-style: wavy" styles))
              (when (setq color (esh--normalize-color color))
                (push (concat "text-decoration-color: #" color) styles)))
             (_ (error "Unexpected underline %S" val))))
          (`display
           (pcase val
             (`(raise ,amount)
              (setq raised t) ;;FIXME handle amount < 0 case
              (push (format "bottom: %gem" amount) styles))
             ((pred stringp)
              (setq children (list val)))
             (_ (error "Unexpected display property %S" val))))
          (`invisible
           (when val (setq children nil)))
          (`non-ascii
           (when val (setq non-ascii t)))
          ;; FIXME handle background colors extending past end of line
          (`newline
           (cl-assert (null styles)))
          (_ (error "Unexpected property %S" property)))))
    (if (null children) nil
      (cl-assert (or styles non-ascii))
      (when styles
        (let ((attrs `((style . ,(mapconcat #'identity styles ";")))))
          (setq children `((span ,attrs ,@children)))))
      (when non-ascii ;; Aligning wide characters properly requires nested divs
        (setq children `((span ((class . "non-ascii")) (span nil ,@children)))))
      (when raised
        (setq children `((span ((class . "raised"))
                               (span ((class . "raised-text")) ,@children)
                               (span ((class . "raised-phantom")) ,@children)))))
      (car children))))

(defun esh--html-export-tree (tree)
  "Export a single TREE to HTML."
  (pcase tree
    (`(text ,start ,end)
     (buffer-substring-no-properties start end))
    (`(tag ,attributes . ,trees)
     (esh--html-export-tag-node attributes trees))))

(defun esh--html-export (trees)
  "Export TREES to HTML."
  (delq nil (mapcar #'esh--html-export-tree trees)))

(defun esh--htmlify-current-buffer ()
  "Export current buffer to HTML."
  (let ((inhibit-modification-hooks t))
    (esh--commit-compositions)
    (esh--mark-newlines)
    (esh--mark-non-ascii))
  (let ((trees (let ((esh-interval-tree-nest-annotations nil))
                 (esh--buffer-to-property-trees
                  esh--html-props
                  esh--html-face-attrs
                  esh--html-priorities))))
    (esh--html-export trees)))

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
                    ,@(esh--export-str code mode-fn #'esh--htmlify-current-buffer)))
         `(,tag ,attributes
                ,@(mapcar (lambda (c)
                            (esh--htmlify-do-tree c))
                          children)))))))

(defvar esh-html-before-parse-hook nil
  "Hook called before parsing input HTML.
Hook may e.g. make modifications to the buffer.")

(defun esh--html-read-tag (tag)
  "Read HTML TAG at point in current buffer."
  (when (looking-at (format "<%s [^>]+>" (regexp-quote tag)))
    (goto-char (match-end 0))
    (skip-chars-forward " \n\t")
    (buffer-substring-no-properties (match-beginning 0) (point))))

(defun esh2html-current-buffer ()
  "Fontify contents of all ESH blocks in current document.
Highlight sources in any environments containing a class matching
`esh--html-src-class-prefix', such as `src-c', `src-ocaml', etc."
  (interactive)
  (run-hook-with-args 'esh-html-before-parse-hook)
  (goto-char (point-min))
  (unwind-protect
      (let* ((xml-decl (esh--html-read-tag "?xml"))
             (doctype (esh--html-read-tag "!doctype"))
             (tree (libxml-parse-html-region (point) (point-max)))
             (esh--html-src-class-re (format "\\_<%s\\([^ ]+\\)\\_>"
                                          esh--html-src-class-prefix)))
        (erase-buffer)
        (dolist (tag (list xml-decl doctype))
          (when tag (insert tag)))
        (esh--htmlify-serialize (esh--htmlify-do-tree tree) t))
    (esh--kill-temp-buffers)))

(defun esh2html-html-file (path)
  "Fontify contents of all ESH environments in PATH."
  (with-temp-buffer
    (esh--insert-file-contents path)
    (esh2html-current-buffer)
    (buffer-string)))

(provide 'esh)
;;; esh.el ends here

;; Local Variables:
;; checkdoc-arguments-in-order-flag: nil
;; End:
