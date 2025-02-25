;;; org-anki.el --- Synchronize org-mode entries to Anki -*- lexical-binding: t -*-
;;
;; Copyright (C) 2022 Markus Läll
;;
;; URL: https://github.com/eyeinsky/org-anki
;; Version: 1.0.2
;; Author: Markus Läll <markus.l2ll@gmail.com>
;; Keywords: outlines, flashcards, memory
;; Package-Requires: ((emacs "27.1") (request "0.3.2") (dash "2.17") (promise "1.1"))

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <http://www.gnu.org/licenses/>.


;;; Commentary:

;; Minor mode to synchronize org-mode entries to Anki via AnkiConnect.
;;
;; See https://github.com/eyeinsky/org-anki for more.


;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'json)
(require 'org)
(require 'org-element)
(require 'promise)
(require 'request)
(require 'thunk)

;; Constants

(defconst org-anki-prop-note-id "ANKI_NOTE_ID")
(defconst org-anki-prop-deck "ANKI_DECK")
(defconst org-anki-match "ANKI_MATCH")
(defconst org-anki-note-type "ANKI_NOTE_TYPE")
(defconst org-anki-prop-global-tags "ANKI_TAGS")

;; Customizable variables

(defcustom org-anki-default-deck nil
  "Default deck name if none is set on the org item nor as global
property"
  :type '(string)
  :group 'org-anki)

(defcustom org-anki-default-match nil
  "Default match used in `org-map-entries` for sync all."
  :type '(string)
  :group 'org-anki)

(defcustom org-anki-default-note-type "Basic"
  "Default note type."
  :type '(string)
  :group 'org-anki)

(defcustom org-anki-ankiconnnect-listen-address "http://127.0.0.1:8765"
  "The address of AnkiConnect"
  :type '(string)
  :group 'org-anki)

(defcustom org-anki-model-fields
  '(("Basic" "Front" "Back")
    ("Basic (and reversed card)" "Front" "Back")
    ("Basic (optional reversed card)" "Front" "Back")
    ("NameDescr" "Name" "Descr")
    ("Cloze" "Text"))
  "Default fields for note types."
  :type '(repeat (list (repeat string)))
  :group 'org-anki)

(defcustom org-anki-inherit-tags t
  "Inherit tags, set to nil to turn off."
  :type 'boolean
  :group 'org-anki)

;; Stolen code

;; Get list of global properties
;;
;; From:
;;   https://emacs.stackexchange.com/questions/21713/how-to-get-property-values-from-org-file-headers
(defun org-anki--global-props (&optional name buffer)
  "Get the plists of global org properties by NAME in BUFFER.

Default NAME is \"PROPERTY\", default BUFFER the current buffer."
  (unless name (setq name "PROPERTY"))
  (with-current-buffer (or buffer (current-buffer))
    (org-element-map (org-element-parse-buffer) 'keyword
      (lambda (el) (when (string-match name (org-element-property :key el)) el))
      nil t)))

(defun org-anki--get-global-prop (name)
  "Get global property by NAME."
  (plist-get (car (cdr (org-anki--global-props name))) :value))


;; AnkiConnect API

(defun org-anki-connect-request (body on-result on-error)
  "Perform HTTP GET request to AnkiConnect, address is
customizable by the org-anki-ankiconnnect-listen-address variable.

BODY is the alist json payload, CALLBACK the function to call
with result."
  (let ((json (json-encode `(("version" . 6) ,@body))))
    (request
      org-anki-ankiconnnect-listen-address
      :type "GET"
      :data json
      :headers '(("Content-Type" . "application/json"))
      :parser 'json-read

      :error
      (cl-function
       (lambda (&rest _args)
         (debug "Error response in variable '_args'")))

      :success
      (cl-function
       (lambda (&key data &allow-other-keys)
         (let ((the-error (assoc-default 'error data))
               (the-result (assoc-default 'result data)))
           (if the-error
               (if on-error
                   (funcall on-error the-error)
                 (error "Unhandled error: %s" the-error))
           (funcall on-result the-result))))))))

(defun org-anki--get-current-tags (ids)
  ;; :: [Id] -> Promise [[Tag]]
  (promise-new
   (lambda (resolve reject)
     (org-anki-connect-request
      (org-anki--notes-info ids)
      (lambda (the-result)
        (funcall
         resolve
         (-map
          (lambda (arg) (append (assoc-default 'tags arg) nil))
          (append the-result nil))))
      (lambda (the-error) (funcall reject the-error))))))

;; Note

(cl-defstruct org-anki--note maybe-id front back tags deck type point)

(defun org-anki--back-post-processing (text)
  (org-anki--string-to-anki-mathjax text)
  )

(defun org-anki--string-to-anki-mathjax (latex-code)
  (let ((delimiter-map (list (cons (regexp-quote "\\begin{equation}") "\\\\[")
                             (cons (regexp-quote "\\end{equation}") "\\\\]")
                             (cons (regexp-quote "\\begin{align}") "\\\\[\n\\\\begin{aligned}")
                             (cons (regexp-quote "\\end{align}") "\\\\end{aligned}\n\\\\]")))
        (matched nil))
    (dolist (delimiter delimiter-map)
      (setq latex-code (replace-regexp-in-string (car delimiter) (cdr delimiter) latex-code))))
  latex-code
  )

(defun org-anki--note-at-point ()
  (let
      ((maybe-id (org-entry-get nil org-anki-prop-note-id))
       (front (org-anki--string-to-html (org-entry-get nil "ITEM")))
       (back (org-anki--back-post-processing (org-anki--string-to-html (org-anki--entry-content-until-any-heading))))
       (tags (org-anki--get-tags))
       (deck (org-anki--find-prop org-anki-prop-deck org-anki-default-deck))
       (type (org-anki--find-prop org-anki-note-type org-anki-default-note-type))
       (note-start (point)))
    (make-org-anki--note
     :maybe-id (if (stringp maybe-id) (string-to-number maybe-id))
     :front    front
     :back     back
     :tags     tags
     :deck     deck
     :type     type
     :point    note-start)))

;;; JSON payloads

(defun org-anki--body (action params)
  "Wrap ACTION and PARAMS to a json payload AnkiConnect expects."
  `(("action" . ,action)
    ("params" . ,params)))

(defun org-anki--create-note-single (note)
  "Create an `addNote' json structure to be added to DECK with
card FRONT and BACK strings."
  (org-anki--body
   "addNote"
   `(("note" .
      (("deckName" . ,(org-anki--note-deck note))
       ,@(org-anki--to-fields note)
       ("tags" . ,(if (org-anki--note-tags note) (org-anki--note-tags note) ""))
       ("options" .
        (("allowDuplicate" . :json-false)
         ("duplicateScope" . "deck"))))))))

(defun org-anki--update-note-single (note)
  "Create an `updateNoteFields' json structure with integer ID,
and NEW-FRONT and NEW-BACK strings."
  (org-anki--body
   "updateNoteFields"
   `(("note" .
      (("id" . ,(org-anki--note-maybe-id note))
       ,@(org-anki--to-fields note))))))

(defun org-anki--tag-diff (current note)
  "Calculate new tags that need to be added and tags that need to
be removed from the Anki app, return actions that do that."
  ;; :: [Tag] -> Note -> [Action]
  (let*
      ((new (org-anki--note-tags note))
       (remove (cl-set-difference current new :test #'equal))
       (add (cl-set-difference new current :test #'equal)))
    `(,@(if remove
            `(,(org-anki--remove-tags (org-anki--note-maybe-id note) remove)))
      ,@(if add
            `(,(org-anki--add-tags (org-anki--note-maybe-id note) add))))))

(defun org-anki--to-fields (note)
  "Convert NOTE to json fields sent to AnkiConnect.

Note type is used to choose field names for the note.

If title or content field contains Cloze syntax then that field
is used for both the question and answer and the other field is
ignored."
  (let*
      ((front (org-anki--note-front note))
       (back (org-anki--note-back note))
       (model-name-and-field-values
        (cond
         ((org-anki--is-cloze front) `("Cloze" ,front ,back))
         ((org-anki--is-cloze back) `("Cloze" ,back ,front))
         (t `(,(org-anki--note-type note) ,front ,back))
         ))
       (model-name (car model-name-and-field-values))
       (field-values (cdr model-name-and-field-values))
       (field-names (cdr (assoc model-name org-anki-model-fields)))
       (fields (-zip field-names field-values)))

    `(("modelName" . ,model-name)
      ("fields" . ,fields))))

(defun org-anki--delete-notes (ids)
  "Create an `deleteNotes' json structure with integer IDS list."
  (org-anki--body "deleteNotes" `(("notes" . ,ids))))

(defun org-anki--multi (actions)
  (org-anki--body "multi" `(("actions" . ,actions))))

(defun org-anki--notes-info (note-ids)
  (org-anki--body "notesInfo" `(("notes" . ,note-ids))))

(defun org-anki--add-tags (note-id tags)
  (let ((tags_ (mapconcat 'identity tags " ")))
  (org-anki--body "addTags" `(("notes" ,note-id) ("tags" . ,tags_)))))

(defun org-anki--remove-tags (note-id tags)
  (let ((tags_ (mapconcat 'identity tags " ")))
    (org-anki--body "removeTags" `(("notes" ,note-id) ("tags" . ,tags_)))))

;; org-mode

(defun org-anki--entry-content-until-any-heading ()
  "Get entry content until any next heading."
  ;; We move around with regexes, so restore original position
  (save-excursion
    ;; Jump to beginning of entry
    (goto-char (org-entry-beginning-position)) ;; was: (re-search-backward "^\\*+ .*\n")
    ;; Skip heading
    (re-search-forward ".*\n")
    ;; Possibly skip property block until end of entry
    (re-search-forward ":properties:\\(.*\n\\)*:end:" (org-entry-end-position) t)
    ;; Get entry content
    (let ((from (point))
          (to (progn (outline-next-heading) (point))))
      (buffer-substring-no-properties from to))))

(defun org-anki--string-to-html (string)
  "Convert STRING (org element heading or content) to html."
  (save-excursion (org-export-string-as string 'html t '(:with-toc nil))))

(defun org-anki--report-error (format error)
  "FORMAT the ERROR and prefix it with `org-anki error'."
  (let ((fmt0 (concat "org-anki error: " format)))
    (message fmt0 error)))

(defun org-anki--no-action () (message "No action taken."))

(defun org-anki--find-prop (name default)
  "Find property with NAME from
1. item,
2. inherited from parents
3. as in-buffer setting
4. otherwise use DEFAULT"
  (thunk-let
   ((prop-item (org-entry-get nil name t))
    (prop-global (org-anki--get-global-prop name)))
    (cond
     ((stringp prop-item) prop-item)
     ((stringp prop-global) prop-global)
     ((stringp default) default)
     (t (error "No property '%s' in item nor file nor set as default!"
               name)))))

(defun org-anki--get-match ()
  (let
   ((file-global (org-anki--get-global-prop org-anki-match)))
    (if (stringp file-global) file-global org-anki-default-match)))

(defun org-anki--get-tags ()
  (delete-dups
   (split-string
    (let ((global-tags (org-anki--get-global-prop org-anki-prop-global-tags)))
      (concat
       (if org-anki-inherit-tags
           (substring-no-properties (or (org-entry-get nil "ALLTAGS") ""))
         (org-entry-get nil "TAGS"))
       global-tags)) ":" t)))

;;; Cloze

(defun org-anki--is-cloze (text)
  "Check if TEXT has cloze syntax, return nil if not."
  ;; Check for something similar to {{c1::Hidden-text::Hint}} in TEXT
  (if (string-match "{{c[0-9]+::\\(\n\\|.\\)*}}" text)
      "Cloze"
    nil))

;; Stolen from https://github.com/louietan/anki-editor
(defun org-anki--region-to-cloze (begin end arg hint)
  "Cloze region from BEGIN to END with number ARG."
  (let ((region (buffer-substring begin end)))
    (save-excursion
      (delete-region begin end)
      (insert (with-output-to-string
                (princ (format "{{c%d::%s" (or arg 1) region))
                (unless (string-blank-p hint) (princ (format "::%s" hint)))
                (princ "}}"))))))

;; Helpers

(defun org-anki--partition (fn list)
  (seq-reduce
   (lambda (acc e)
     (let*
         ((res (funcall fn e))
          (label (car res))
          (value (cdr res))
          (lefts (car acc))
          (rights (cdr acc)))
       (cond
        ((equal label :left) `(,(cons value lefts) . ,rights))
        ((equal label :right) `(,lefts . ,(cons value rights))))))
   list '(nil . nil)))

(defun org-anki--get-point (note-action-result)
  ;; :: ((Note, Action), Result) -> Point
  (org-anki--note-point (car (car note-action-result))))

(defun org-anki--handle-pair (pair)
  ;; :: ((Note, Action), Result) -> IO ()
  (let*
      ((note-with-action (car pair))
       (note (car note-with-action))
       (action (cdr note-with-action))
       (result (car (cdr pair))))
    (cond
     ;; added note
     ((equal "addNote" (assoc-default "action" action))
      (save-excursion
        (goto-char (org-anki--note-point note))
        (org-set-property org-anki-prop-note-id (number-to-string result))))
     ;; update note
     ((equal "updateNoteFields" (assoc-default "action" action))
      (message "org-anki: note succesfully updated: %s" (org-anki--note-maybe-id note))))))

(defun org-anki--existing-tags (notes)
  ;; :: [Note] -> Promise (AList Id [Tag])
  (promise-new
   (lambda (resolve reject)
     (let ((existing (-filter 'org-anki--note-maybe-id notes)))
       (if existing
           (let ((ids (-map 'org-anki--note-maybe-id existing)))
             (promise-chain (org-anki--get-current-tags ids)
               (then (lambda (existing-tags)
                       (funcall resolve (-zip-with 'cons ids existing-tags))))
               (promise-catch (lambda (reason) (funcall reject reason)))))
         (funcall resolve nil))))))

(defun org-anki--execute-api-actions (note-action-pairs)
  (let ((actions (--map (cdr it) note-action-pairs)))
    (org-anki-connect-request
     (org-anki--multi actions)
     (lambda (the-result)
       (let*
           ((result-list (append the-result nil))
            (pairs (-zip-lists note-action-pairs result-list))
            (sorted
             (-sort
              (lambda (a b)
                (> (org-anki--get-point a) (org-anki--get-point b)))
              pairs))
            )
         (-map 'org-anki--handle-pair sorted)))
     (lambda (the-error)
       (org-anki--report-error
        "Couldn't update note, received: %s"
        the-error)))))

(defun org-anki--sync-notes (notes)
  ;; :: [Note] -> IO ()
  "Syncronize NOTES."

  (if notes
      (promise-chain
          (org-anki--existing-tags notes)
        (then
         (lambda (all-existing-tags)
           (let*
               (
                ;; Calculate added and updated notes
                (new-and-existing
                 (org-anki--partition
                  (lambda (note)
                    (cond
                     ((org-anki--note-maybe-id note) (cons :right note))
                     (t                              (cons :left note))))
                  notes))
                (new (car new-and-existing))      ;; [Note]
                (existing (cdr new-and-existing)) ;; [Note]
                (additions (--map (cons it (org-anki--create-note-single it)) new))      ;; [(Note, Action)]
                (updates   (--map (cons it (org-anki--update-note-single it)) existing)) ;; [(Note, Action)]

                ;; Calculate added and removed tags
                (notes-and-tag-actions ;; [(Note, [Action])]
                 (-map
                  (lambda (note-and-action)
                    (let* ((note (car note-and-action))
                           (existing-tags
                            (cdr (assq (org-anki--note-maybe-id note) all-existing-tags))))
                      (cons note (org-anki--tag-diff existing-tags note))))
                  updates))
                (notes-and-tag-actions2 ;; [(Note, Action)]
                 (--mapcat
                  (let ((note (car it))
                        (actions (cdr it)))
                    (--map (cons note it) actions))
                  notes-and-tag-actions)))

             (if (and (= (length updates) 1) (= (length notes) 1))

                 ;; If there there is only one update, then don't use
                 ;; multi for that:
                 (let* ((pair (car updates))
                        (note (car pair))
                        (action (cdr pair)))

                   (message "one update" action)
                   (org-anki-connect-request
                    action
                    (lambda (the-result)
                      (message
                       "org-anki: note succesfully updated: %s"
                       (org-anki--note-maybe-id note)))
                    (lambda (the-error)
                      (org-anki--report-error
                       "Couldn't update note, received: %s"
                       the-error)))

                   ;; Update tags (if any) for the single note, too:
                   (if notes-and-tag-actions2
                       (org-anki--execute-api-actions notes-and-tag-actions2)))

               ;; It's not just one updated note, default to multi
               (let ((note-action-pairs (-concat additions updates notes-and-tag-actions2))) ;; [(Note, Action)]
                 (org-anki--execute-api-actions note-action-pairs))))))
        (promise-catch (lambda (reason) (error reason))))))

(defun org-anki--delete-notes_ (notes)
  ;; :: [Note] -> IO ()
  (let ((ids (-map 'org-anki--note-maybe-id notes)))
    (if ids
        (org-anki-connect-request
         (org-anki--delete-notes ids)
         (lambda (_)
           (-map
            (lambda (note)
              (save-excursion
                (goto-char (org-anki--note-point note))
                (org-delete-property org-anki-prop-note-id)))
            (reverse notes))
           )
         (lambda (the-error)
           (org-anki--report-error
            "org-anki-delete-all error: %s"
            the-error))))))

;; Public API

;;; Convenience functions

(defun org-anki-add-model (model &rest field-names)
  "Add MODEL with FIELD-NAMES."
  (customize-set-variable
   'org-anki-model-fields
   (cons `(,model ,@field-names) org-anki-model-fields)))

;;; Interactive commands

;;;###autoload
(defun org-anki-sync-entry ()
  ;; :: IO ()
  "Synchronize entry at point."
  (interactive)
  (org-anki--sync-notes (cons (org-anki--note-at-point) nil)))

;;;###autoload
(defun org-anki-sync-all (&optional buffer)
  ;; :: Maybe Buffer -> IO ()
  "Syncronize all entries in optional BUFFER."
  (interactive)
  (with-current-buffer (or buffer (buffer-name))
    (org-anki--sync-notes
     (org-map-entries 'org-anki--note-at-point (org-anki--get-match)))))

;;;###autoload
(defun org-anki-update-all (&optional buffer)
  ;; :: Maybe Buffer -> IO ()
  "Updates all entries in optional BUFFER.

Updates all entries that have ANKI_NOTE_ID property set."
  (interactive)
  (with-current-buffer (or buffer (buffer-name))
    (org-anki--sync-notes
     (org-map-entries 'org-anki--note-at-point "ANKI_NOTE_ID<>\"\""))))

;;;###autoload
(defun org-anki-delete-entry ()
  ;; :: IO ()
  "Delete org entry under cursor."
  (interactive)
  (let ((msg (format "Delete note '%s'?" (org-entry-get nil "ITEM"))))
    (if (y-or-n-p msg)
        (org-anki--delete-notes_ (cons (org-anki--note-at-point) nil))
      (org-anki--no-action))))

(defun org-anki-delete-all (&optional buffer)
  "Delete all entries in BUFFER, use current buffer if not specified."
  ;; :: Maybe Buffer -> IO ()
  (interactive)
  (let* ((buffer-name_ (or buffer (buffer-name)))
         (prompt (format "Are you sure you want to delete all notes in buffer '%s' from Anki?" buffer-name_)))
    (if (y-or-n-p prompt)
        (with-current-buffer buffer-name_
          (org-anki--delete-notes_
           (org-map-entries 'org-anki--note-at-point "ANKI_NOTE_ID<>\"\"")))
      (org-anki--no-action))))

;; Stolen from https://github.com/louietan/anki-editor
;;;###autoload
(defun org-anki-cloze-dwim (&optional arg hint)
  "Convert current active region or word under cursor to Cloze
syntax."
  (interactive "p\nsHint (optional): ")
  (cond
   ((region-active-p)
    (org-anki--region-to-cloze (region-beginning) (region-end) arg hint))
   ((thing-at-point 'word)
    (let ((bounds (bounds-of-thing-at-point 'word)))
      (org-anki--region-to-cloze (car bounds) (cdr bounds) arg hint)))
   (t (error "Nothing to create cloze from"))))

;;;###autoload
(defun org-anki-browse-entry ()
  "Browse entry at point on anki's browser dialog with searching nid"
  (interactive)
  (let ((maybe-id (org-entry-get nil org-anki-prop-note-id)))
    (cond
     ((stringp maybe-id)
      (org-anki-connect-request
       (org-anki--body
        "guiBrowse"
        `(("query" . ,(concat "nid:" maybe-id))))
       (lambda (the-result)
         (message "org-anki: send request succesfully, please switch to anki"))
       (lambda (the-error)
         (org-anki--report-error
          "Browse error, received: %s"
          the-error)
         )))
     (t (message "org-anki: no note id here")))))

;;;###autoload
(defun org-anki-import-deck (name &optional buffer)
  "Import deck with NAME to current buffer, or to BUFFER when provided.

This is a best-effort command which doesn't support all of Anki's features. Its use case is to import a deck to an .org which from then on will be used as source-of-truth for the notes.

Pandoc is required to be installed."

  (interactive "sDeck name: ")
  (org-anki-connect-request
   (org-anki--body
    "findNotes"
    `(("query" . ,(concat "deck:" name))))
   (lambda (ids)
     (org-anki-connect-request
      (org-anki--body "notesInfo" `(("notes" . ,ids)))
      (lambda (the-result)
        (insert (format "\n#+%s: %s\n\n" org-anki-prop-deck name))
        (mapc
         (lambda (json)
           (org-anki--write-note (org-anki--parse-note json)))
         the-result))
      (lambda (the-error)
        (org-anki--report-error "Get deck error, received: %s" the-error))))
   (lambda (the-error)
     (org-anki--report-error "Get deck error, received: %s" the-error))))

(defun org-anki--parse-note (note-json)
  (cl-flet ((field (lambda (symbol &optional assoc-list)
                     (cdr (assoc symbol (or assoc-list note-json))))))
    (let*
        ((type (field 'modelName))
         (fields (field 'fields))
         (front-back
          (cond
           ((equal type "Cloze")
            `( ,(cdr (assoc 'value (cdr (assoc 'Text fields))))
             . nil
             ))
           ((equal type "NameDescr")
            `( ,(cdr (assoc 'value (cdr (assoc 'Name  fields))))
             . ,(cdr (assoc 'value (cdr (assoc 'Descr fields))))))
           ((member type '("Basic" "Basic (and reversed card)" "Basic (optional reversed card)"))
            `( ,(cdr (assoc 'value (cdr (assoc 'Front  fields))))
               . ,(cdr (assoc 'value (cdr (assoc 'Back   fields))))))
           (t
            (org-anki--report-error "Unsupported note type: %s" type)))))

    (make-org-anki--note
     :maybe-id (field 'noteId)
     :front    (org-anki--html-to-org (car front-back))
     :back     (org-anki--html-to-org (cdr front-back))
     :tags     (append (field 'tags) nil)
     ;; :deck     deck
     :type     type
     :point    nil))))


(defun org-anki--html-to-org (html)
  (if html
      (replace-regexp-in-string
       "\n+$" ""
       (shell-command-to-string
        (format "pandoc --wrap=none --from=html --to=org <<< '%s'" html)))
    ""))

(defun org-anki--write-note (note)
  ;; Add title
  (insert "* ")
  (insert (org-anki--note-front note))

  ;; Add tags if any
  (let ((tags (org-anki--note-tags note)))
    (if tags (insert (concat " :" (mapconcat 'identity tags ":") ":"))))

  (insert "\n\n")
  (org-entry-put nil org-anki-prop-note-id (number-to-string (org-anki--note-maybe-id note)))

  ;; Add type if not basic:
  (let ((type (org-anki--note-type note)))
    (if (not (equal type "Basic"))
      (org-entry-put nil org-anki-note-type type)))

  ;; Add content
  (let ((content (org-anki--note-back note)))
    (if content
        (progn
          (insert content)
          (insert "\n")))))

(provide 'org-anki)
;;; org-anki.el ends here
