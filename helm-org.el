;;; helm-org.el --- Helm for org headlines and keywords completion -*- lexical-binding: t -*-

;; Copyright (C) 2012 ~ 2019 Thierry Volpiatto <thierry.volpiatto@gmail.com>
;; Author:      Thierry Volpiatto <thierry.volpiatto@gmail.com>

;; URL: https://github.com/emacs-helm/helm-org
;; Package-Requires: ((helm "3.3") (emacs "24.4"))
;; Version: 1.0

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
;; 
;; Helm for org headlines and keywords completion

;;; Code:
(require 'cl-lib)
(require 'helm)
(require 'helm-utils)
(require 'org)

(defvar helm-completing-read-handlers-alist)

;; Menu
;;;###autoload
(progn
  (require 'helm-easymenu)
  (easy-menu-add-item
   nil '("Tools" "Helm")
   '("Org"
     ["Org headlines in org agenda files" helm-org-agenda-files-headings t]
     ["Org headlines in buffer" helm-org-in-buffer-headings t])
   "Elpa"))


;; Load org-with-point-at macro when compiling
(eval-when-compile
  (require 'org-macs))

(declare-function org-agenda-switch-to "org-agenda.el")

(defgroup helm-org nil
  "Org related functions for helm."
  :group 'helm)

(defcustom helm-org-headings-fontify nil
  "Fontify org buffers before parsing them.
This reflect fontification in `helm-buffer' when non--nil.
NOTE: This will be slow on large org buffers."
  :group 'helm-org
  :type 'boolean)

(defcustom helm-org-format-outline-path nil
  "Show all org level as path."
  :group 'helm-org
  :type 'boolean)

(defcustom helm-org-show-filename nil
  "Show org filenames in `helm-org-agenda-files-headings' when non--nil.
Note this have no effect in `helm-org-in-buffer-headings'."
  :group 'helm-org
  :type 'boolean)

(defcustom helm-org-headings-min-depth 1
  "Minimum depth of org headings to start with."
  :group 'helm-org
  :type 'integer)

(defcustom helm-org-headings-max-depth 8
  "Go down to this maximum depth of org headings."
  :group 'helm-org
  :type 'integer)

(defcustom helm-org-headings-actions
  '(("Go to heading" . helm-org-goto-marker)
    ("Open in indirect buffer `C-c i'" . helm-org--open-heading-in-indirect-buffer)
    ("Refile heading(s) (marked-to-selected|current-to-selected) `C-c w`" . helm-org--refile-heading-to)
    ("Insert link to this heading `C-c l`" . helm-org-insert-link-to-heading-at-marker))
  "Default actions alist for `helm-source-org-headings-for-files'."
  :group 'helm-org
  :type '(alist :key-type string :value-type function))

(defcustom helm-org-truncate-lines t
  "Truncate org-header-lines when non-nil."
  :type 'boolean
  :group 'helm-org)

(defcustom helm-org-ignore-autosaves nil
  "Ignore autosave files when starting `helm-org-agenda-files-headings'."
  :type 'boolean
  :group 'helm-org)


;;; Help
;;
(defvar helm-org-headings-help-message
  "* Helm Org headings

** Tips

*** Refiling

You can refile one or more headings at a time.

To refile one heading, move the point to the entry you want to refile and run
\\[helm-org-in-buffer-headings].  Then select the heading you want to refile to
and press \\<helm-org-headings-map>\\[helm-org-run-refile-heading-to] or select the refile action from the actions menu.

To refile multiple headings, run \\[helm-org-in-buffer-headings] and mark the
headings you want to refile.  Then select the heading you want to refile to
\(without marking it) and press \\<helm-org-headings-map>\\[helm-org-run-refile-heading-to] or select the refile action from the
actions menu.

*** Tags completion

Tags completion use `completing-read-multiple', perhaps have a
look at its docstring.

**** Single tag

From an org heading hit C-c C-c which provide a
\"Tags\" prompt, then hit TAB and RET if you want to enter an
existing tag or write a new tag in prompt.  At this point you end
up with an entry in your prompt, if you enter RET, the entry is
added as tag in your org header.

**** Multiple tags

If you want to add more tag to your org header, add a separator[1] after
your tag and write a new tag or hit TAB to find another existing
tag, and so on until you have all the tags you want
e.g \"foo,bar,baz\" then press RET to finally add the tags to your
org header.
Note: [1] A separator can be a comma, a colon i.e. [,:] or a space.

** Commands
\\<helm-org-headings-map>
\\[helm-org-run-open-heading-in-indirect-buffer]\t\tOpen heading in indirect buffer.
\\[helm-org-run-refile-heading-to]\t\tRefile current or marked headings to selection.
\\[helm-org-run-insert-link-to-heading-at-marker]\t\tInsert link at point to selection."
  )

;;; Org capture templates
;;
;;
(defvar org-capture-templates)
(defun helm-source-org-capture-templates ()
  "Build source for org capture templates."
  (helm-build-sync-source "Org Capture Templates:"
    :candidates (cl-loop for template in org-capture-templates
                         collect (cons (nth 1 template) (nth 0 template)))
    :action '(("Do capture" . (lambda (template-shortcut)
                                (org-capture nil template-shortcut))))))

;;; Org headings
;;
;;
(defun helm-org-goto-marker (marker)
  "Go to MARKER in org buffer."
  (switch-to-buffer (marker-buffer marker))
  (goto-char (marker-position marker))
  (org-show-context)
  (re-search-backward "^\\*+ " nil t)
  (org-show-entry)
  (org-show-children))

(defun helm-org--open-heading-in-indirect-buffer (marker)
  "Open org heading at MARKER in indirect buffer."
  (helm-org-goto-marker marker)
  (org-tree-to-indirect-buffer)

  ;; Put the non-indirect buffer at the bottom of the prev-buffers
  ;; list so it won't be selected when the indirect buffer is killed
  (set-window-prev-buffers nil (append (cdr (window-prev-buffers))
                                       (car (window-prev-buffers)))))

(defun helm-org-run-open-heading-in-indirect-buffer ()
  "Open selected Org heading in an indirect buffer."
  (interactive)
  (with-helm-alive-p
    (helm-exit-and-execute-action #'helm-org--open-heading-in-indirect-buffer)))
(put 'helm-org-run-open-heading-in-indirect-buffer 'helm-only t)

(defvar helm-org-headings-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map helm-map)
    (define-key map (kbd "C-c i") 'helm-org-run-open-heading-in-indirect-buffer)
    (define-key map (kbd "C-c w") 'helm-org-run-refile-heading-to)
    (define-key map (kbd "C-c l") 'helm-org-run-insert-link-to-heading-at-marker)
    map)
  "Keymap for `helm-source-org-headings-for-files'.")

(defclass helm-org-headings-class (helm-source-sync)
  ((parents
    :initarg :parents
    :initform nil
    :custom boolean)
   (match :initform
          (lambda (candidate)
            (string-match
             helm-pattern
             (helm-aif (get-text-property 0 'helm-real-display candidate)
                 it
               candidate))))
   (help-message :initform 'helm-org-headings-help-message)
   (action :initform 'helm-org-headings-actions)
   (keymap :initform 'helm-org-headings-map)
   (group :initform 'helm-org)))

(defmethod helm--setup-source :after ((source helm-org-headings-class))
  (let ((parents (slot-value source 'parents)))
    (setf (slot-value source 'candidate-transformer)
          (lambda (candidates)
            (let ((cands (helm-org-get-candidates candidates parents)))
              (if parents (nreverse cands) cands))))))

(defun helm-source-org-headings-for-files (filenames &optional parents)
  "Build source for org headings in files FILENAMES.
When PARENTS is specified, bild source for heading that are parents of
current heading."
  (helm-make-source "Org Headings" 'helm-org-headings-class
    :filtered-candidate-transformer 'helm-org-startup-visibility
    :parents parents
    :candidates filenames))

(defun helm-org-startup-visibility (candidates _source)
  "Indent headings and hide leading stars displayed in the helm buffer.
If `org-startup-indented' and `org-hide-leading-stars' are nil, do
nothing to CANDIDATES."
  (cl-loop for i in candidates
	   collect
           ;; Transformation is not needed if these variables are t.
	   (if (or helm-org-show-filename helm-org-format-outline-path)
	       (cons
		(car i) (cdr i))
             (cons
              (if helm-org-headings-fontify
                  (when (string-match "^\\(\\**\\)\\(\\* \\)\\(.*\n?\\)" (car i))
                    (replace-match "\\1\\2\\3" t nil (car i)))
                (when (string-match "^\\(\\**\\)\\(\\* \\)\\(.*\n?\\)" (car i))
                  (let ((foreground (org-find-invisible-foreground)))
                    (with-helm-current-buffer
                      (cond
                       ;; org-startup-indented is t, and org-hide-leading-stars is t
                       ;; Or: #+STARTUP: indent hidestars
                       ((and org-startup-indented org-hide-leading-stars)
                        (with-helm-buffer
                          (require 'org-indent)
                          (org-indent-mode 1)
                          (replace-match
                           (format "%s\\2\\3"
                                   (propertize (replace-match "\\1" t nil (car i))
                                               'face `(:foreground ,foreground)))
                           t nil (car i))))
                       ;; org-startup-indented is nil, org-hide-leading-stars is t
                       ;; Or: #+STARTUP: noindent hidestars
                       ((and (not org-startup-indented) org-hide-leading-stars)
                        (with-helm-buffer
                          (replace-match
                           (format "%s\\2\\3"
                                   (propertize (replace-match "\\1" t nil (car i))
                                               'face `(:foreground ,foreground)))
                           t nil (car i))))
                       ;; org-startup-indented is nil, and org-hide-leading-stars is nil
                       ;; Or: #+STARTUP: noindent showstars
                       (t
                        (with-helm-buffer
                          (replace-match "\\1\\2\\3" t nil (car i)))))))))
              (cdr i)))))

(defun helm-org-get-candidates (filenames &optional parents)
  "Get org headings for file FILENAMES.
Get PARENTS of heading when specified."
  (apply #'append
         (mapcar (lambda (filename)
                   (helm-org--get-candidates-in-file
                    filename
                    helm-org-headings-fontify
                    (or parents (null helm-org-show-filename))
                    parents))
                 filenames)))

(defun helm-org--get-candidates-in-file (filename &optional fontify nofname parents)
  "Get candidates for org FILENAME.
Fontify each heading when FONTIFY is specified.
Don't show filename when NOFNAME.
Get PARENTS as well when specified."
  (with-current-buffer (pcase filename
                         ((pred bufferp) filename)
                         ((pred stringp) (find-file-noselect filename t)))
    (let ((match-fn (if fontify
                        #'match-string
                      #'match-string-no-properties))
          (search-fn (lambda ()
                       (re-search-forward
                        org-complex-heading-regexp nil t)))
          (file (unless (or (bufferp filename) nofname)
                  (concat (helm-basename filename) ":"))))
      (when parents
        (add-function :around (var search-fn)
                      (lambda (old-fn &rest args)
                                (when (org-up-heading-safe)
                                  (apply old-fn args)))))
      (save-excursion
        (save-restriction
          (unless (and (bufferp filename)
                       (buffer-base-buffer filename))
            ;; Only widen direct buffers, not indirect ones.
            (widen))
          (unless parents (goto-char (point-min)))
          ;; clear cache for new version of org-get-outline-path
          (and (boundp 'org-outline-path-cache)
               (setq org-outline-path-cache nil))
          (cl-loop with width = (window-width (helm-window))
                   while (funcall search-fn)
                   for beg = (point-at-bol)
                   for end = (point-at-eol)
                   when (and fontify
                             (null (text-property-any
                                    beg end 'fontified t)))
                   do (jit-lock-fontify-now beg end)
                   for level = (length (match-string-no-properties 1))
                   for heading = (funcall match-fn 4)
                   if (and (>= level helm-org-headings-min-depth)
                           (<= level helm-org-headings-max-depth))
                   collect `(,(propertize
                               (if helm-org-format-outline-path
                                   (org-format-outline-path
                                    ;; org-get-outline-path changed in signature and behaviour since org's
                                    ;; commit 105a4466971. Let's fall-back to the new version in case
                                    ;; of wrong-number-of-arguments error.
                                    (condition-case nil
                                        (append (apply #'org-get-outline-path
                                                       (unless parents
                                                         (list t level heading)))
                                                (list heading))
                                      (wrong-number-of-arguments
                                       (org-get-outline-path t t)))
                                    width file)
                                   (if file
                                       (concat file (funcall match-fn  0))
                                       (funcall match-fn  0)))
                               'helm-real-display heading)
                              . ,(point-marker))))))))

(defun helm-org-insert-link-to-heading-at-marker (marker)
  "Insert link to heading at MARKER position."
  (with-current-buffer (marker-buffer marker)
    (let ((bracket-link (save-excursion
                          (goto-char (marker-position marker))
                          (org-link-unescape
                           (org-store-link nil nil)))))
      (with-helm-current-buffer
        (string-match org-bracket-link-regexp bracket-link)
        (org-insert-link nil (match-string 1 bracket-link))))))

(defun helm-org-run-insert-link-to-heading-at-marker ()
  "Run interactively `helm-org-insert-link-to-heading-at-marker'."
  (interactive)
  (with-helm-alive-p
    (helm-exit-and-execute-action
     'helm-org-insert-link-to-heading-at-marker)))

(defun helm-org--refile-heading-to (marker)
  "Refile headings to heading at MARKER.
If multiple candidates are marked in the Helm session, they will
all be refiled.  If no headings are marked, the selected heading
will be refiled."
  (let* ((victims (with-helm-buffer (helm-marked-candidates)))
         (buffer (marker-buffer marker))
         (filename (buffer-file-name buffer))
         (rfloc (list nil filename nil marker)))
    (when (and (= 1 (length victims))
               (equal (helm-get-selection) (car victims)))
      ;; No candidates are marked; we are refiling the entry at point
      ;; to the selected heading
      (setq victims (list (point))))
    ;; Probably best to check that everything returned a value
    (when (and victims buffer filename rfloc)
      (cl-loop for victim in victims
               do (org-with-point-at victim
                    (org-refile nil nil rfloc))))))

(defun helm-org-in-buffer-preselect ()
  "Return the current or closest visible heading as a regexp string."
  (save-excursion
    (cond ((org-at-heading-p) (forward-line 0))
	  ((org-before-first-heading-p)
	   (outline-next-visible-heading 1))
	  (t (outline-previous-visible-heading 1)))
    (regexp-quote (buffer-substring-no-properties (point)
						  (point-at-eol)))))

(defun helm-org-run-refile-heading-to ()
  "Helm org refile heading action."
  (interactive)
  (with-helm-alive-p
    (helm-exit-and-execute-action 'helm-org--refile-heading-to)))
(put 'helm-org-run-refile-heading-to 'helm-only t)

;;;###autoload
(defun helm-org-agenda-files-headings ()
  "Preconfigured helm for org files headings."
  (interactive)
  (let ((autosaves (cl-loop for f in (org-agenda-files)
                            when (file-exists-p
                                  (expand-file-name
                                   (concat "#" (helm-basename f) "#")
                                   (helm-basedir f)))
                            collect (helm-basename f))))
    (when (or (null autosaves)
              helm-org-ignore-autosaves
              (y-or-n-p (format "%s have auto save data, continue? "
                                (mapconcat #'identity autosaves ", "))))
      (helm :sources (helm-source-org-headings-for-files (org-agenda-files))
            :candidate-number-limit 99999
            :truncate-lines helm-org-truncate-lines
            :buffer "*helm org headings*"))))

;;;###autoload
(defun helm-org-in-buffer-headings ()
  "Preconfigured helm for org buffer headings."
  (interactive)
  (let (helm-org-show-filename)
    (helm :sources (helm-source-org-headings-for-files
                    (list (current-buffer)))
          :candidate-number-limit 99999
          :preselect (helm-org-in-buffer-preselect)
          :truncate-lines helm-org-truncate-lines
          :buffer "*helm org inbuffer*")))

;;;###autoload
(defun helm-org-parent-headings ()
  "Preconfigured helm for org headings that are parents of the current heading."
  (interactive)
  ;; Use a large max-depth to ensure all parents are displayed.
  (let ((helm-org-headings-min-depth 1)
        (helm-org-headings-max-depth  50))
    (helm :sources (helm-source-org-headings-for-files
                    (list (current-buffer)) t)
          :candidate-number-limit 99999
          :truncate-lines helm-org-truncate-lines
          :buffer "*helm org parent headings*")))

;;;###autoload
(defun helm-org-capture-templates ()
  "Preconfigured helm for org templates."
  (interactive)
  (helm :sources (helm-source-org-capture-templates)
        :candidate-number-limit 99999
        :truncate-lines helm-org-truncate-lines
        :buffer "*helm org capture templates*"))

;;; Org tag completion

;; Based on code from Anders Johansson posted on 3 Mar 2016 at
;; <https://groups.google.com/d/msg/emacs-helm/tA6cn6TUdRY/G1S3TIdzBwAJ>

(defvar crm-separator)

;;;###autoload
(defun helm-org-completing-read-tags (prompt collection pred req initial
                                      hist def inherit-input-method _name _buffer)
  "Completing read function for Org tags.

This function is used as a `completing-read' function in
`helm-completing-read-handlers-alist' by `org-set-tags' and
`org-capture'.

NOTE: Org tag completion will work only if you disable org fast tag
selection, see (info \"(org) setting tags\")."
  (if (not (string= "Tags: " prompt))
      ;; Not a tags prompt.  Use normal completion by calling
      ;; `org-icompleting-read' again without this function in
      ;; `helm-completing-read-handlers-alist'
      (let ((helm-completing-read-handlers-alist
             (rassq-delete-all
              'helm-org-completing-read-tags
              (copy-alist helm-completing-read-handlers-alist))))
        (org-icompleting-read
         prompt collection pred req initial hist def inherit-input-method))
    ;; Tags prompt
    (let* ((curr (and (stringp initial)
                      (not (string= initial ""))
                      (org-split-string initial ":")))
           (table   (delete curr
                            (org-uniquify
                             (mapcar #'car org-last-tags-completion-table))))
           (crm-separator ":\\|,\\|\\s-"))
      (cl-letf (((symbol-function 'crm-complete-word)
                 'self-insert-command))
        (mapconcat #'identity
                   (completing-read-multiple
                    prompt table pred nil initial hist def)
                   ":")))))

(provide 'helm-org)

;; Local Variables:
;; byte-compile-warnings: (not obsolete)
;; coding: utf-8
;; indent-tabs-mode: nil
;; End:

;;; helm-org.el ends here
