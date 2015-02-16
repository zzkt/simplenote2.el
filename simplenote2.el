;;; simplenote2.el --- Interact with simple-note.appspot.com

;; Copyright (C) 2009, 2010 Konstantinos Efstathiou <konstantinos@efstathiou.gr>
;; Copyright (C) 2015 alpha22jp <alpha22jp@gmail.com>

;; for simplenote.el
;; Author: Konstantinos Efstathiou <konstantinos@efstathiou.gr>
;; for simplenote2.el
;; Author: alpha22jp <alpha22jp@gmail.com>
;; Keywords: simplenote
;; Version: 2.0

;; This program is free software; you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free Software
;; Foundation; either version 2 of the License, or (at your option) any later
;; version.

;; This program is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
;; FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
;; details.

;; You should have received a copy of the GNU General Public License along with
;; this program; if not, write to the Free Software Foundation, Inc., 51
;; Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.


;;; Code:



(eval-when-compile (require 'cl))
(require 'url)
(require 'json)
(require 'widget)
(require 'request-deferred)

(defcustom simplenote2-directory (expand-file-name "~/.simplenote2/")
  "Simplenote directory."
  :type 'directory
  :safe 'stringp
  :group 'simplenote)

(defcustom simplenote2-email nil
  "Simplenote account email."
  :type 'string
  :safe 'stringp
  :group 'simplenote)

(defcustom simplenote2-password nil
  "Simplenote account password."
  :type 'string
  :safe 'stringp
  :group 'simplenote)

(defcustom simplenote2-notes-mode 'text-mode
  "The mode used for editing notes opened from Simplenote.

Since notes do not have file extensions, the default mode must be
set via this option.  Individual notes can override this setting
via the usual `-*- mode: text -*-' header line."
  :type 'function
  :group 'simplenote)

(defcustom simplenote2-note-head-size 78
  "Length of note headline in the notes list."
  :type 'integer
  :safe 'integerp
  :group 'simplenote)

(defcustom simplenote2-show-note-file-name t
  "Show file name for each note in the note list."
  :type 'boolean
  :safe 'booleanp
  :group 'simplenote)

(defvar simplenote2-mode-hook nil)

(put 'simplenote2-mode 'mode-class 'special)

(defvar simplenote2-server-url "https://simple-note.appspot.com/")

(defvar simplenote2-email-was-read-interactively nil)
(defvar simplenote2-password-was-read-interactively nil)

(defvar simplenote2-token nil)

(defvar simplenote2-notes-info (make-hash-table :test 'equal))

(defvar simplenote2-filename-for-notes-info
  (concat (file-name-as-directory simplenote2-directory) ".notes-info.el"))

(defvar simplenote2-filter-note-tag-list nil)


;;; Unitity functions

(defun simplenote2-file-mtime (path)
  (nth 5 (file-attributes path)))

(defun simplenote2-get-file-string (file)
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun simplenote2-tag-existp (tag array)
  "Returns t if there is a string named TAG in array ARRAY, otherwise nil"
  (loop for i from 0 below (length array)
        thereis (string= tag (aref array i))))


;;; Save/Load notes information file

(defconst simplenote2-save-file-header
  ";;; Automatically generated by `simplenote2' on %s.\n"
  "Header to be written into the `simplenote2-save-notes-info'.")

(defsubst simplente2-trunc-list (l n)
  "Return from L the list of its first N elements."
  (let (nl)
    (while (and l (> n 0))
      (setq nl (cons (car l) nl)
            n  (1- n)
            l  (cdr l)))
    (nreverse nl)))

(defun simplenote2-dump-variable (variable &optional limit)
  (let ((value (symbol-value variable)))
    (if (atom value)
        (insert (format "\n(setq %S '%S)\n" variable value))
      (when (and (integerp limit) (> limit 0))
        (setq value (simplenote2-trunc-list value limit)))
      (insert (format "\n(setq %S\n      '(" variable))
      (dolist (e value)
        (insert (format "\n        %S" e)))
      (insert "\n        ))\n"))))

(defun simplenote2-save-notes-info ()
  (condition-case error
      (with-temp-buffer
        (erase-buffer)
        (insert (format simplenote2-save-file-header (current-time-string)))
        (simplenote2-dump-variable 'simplenote2-notes-info)
        (write-file simplenote2-filename-for-notes-info)
        nil)
    (error (warn "Simplenote2: %s" (error-message-string error)))))

(defun simplenote2-load-notes-info ()
  (when (file-readable-p simplenote2-filename-for-notes-info)
    (load-file simplenote2-filename-for-notes-info)))

(defun simplenote2-save-note (note)
  "Save note information and content gotten from server."
  (let ((key (cdr (assq 'key note)))
        (systemtags (cdr (assq 'systemtags note)))
        (createdate (string-to-number (cdr (assq 'createdate note))))
        (modifydate (string-to-number (cdr (assq 'modifydate note))))
        (content (cdr (assq 'content note))))
    ;; Save note information to 'simplenote2-notes-info
    (puthash key (list (cdr (assq 'syncnum note))
                       (cdr (assq 'version note))
                       createdate
                       modifydate
                       (cdr (assq 'tags note))
                       (simplenote2-tag-existp "markdown" systemtags)
                       (simplenote2-tag-existp "pinned" systemtags)
                       nil)
             simplenote2-notes-info)
    ;; Write note content to local file
    ;; "content" may not be returned from server in the case process is "update"
    ;; but content isn't changed
    (when content
      (let ((file (simplenote2-filename-for-note key))
            (text (decode-coding-string content 'utf-8)))
        (write-region text nil file nil)
        (set-file-times file (seconds-to-time modifydate))))
    key))


;;; Simplenote authentication

(defun simplenote2-email ()
  (when (not simplenote2-email)
    (setq simplenote2-email (read-string "Simplenote email: "))
    (setq simplenote2-email-was-read-interactively t))
  simplenote2-email)

(defun simplenote2-password ()
  (when (not simplenote2-password)
    (setq simplenote2-password (read-passwd "Simplenote password: "))
    (setq simplenote2-password-was-read-interactively t))
  simplenote2-password)

(defun simplenote2-get-token-deferred ()
  "Returns simplenote token wrapped with deferred object.

This function returns cached token if it's cached to 'simplenote2-token,\
 otherwise gets token from server using 'simplenote2-email and 'simplenote2-password\
 and cache it."
  (if simplenote2-token
      (deferred:next (lambda () simplenote2-token))
    (deferred:$
      (request-deferred
       (concat simplenote2-server-url "api/login")
       :type "POST"
       :data (base64-encode-string
              (format "email=%s&password=%s"
                      (url-hexify-string (simplenote2-email))
                      (url-hexify-string (simplenote2-password))))
       :parser 'buffer-string)
      (deferred:nextc it
        (lambda (res)
          (if (request-response-error-thrown res)
              (progn
                (if simplenote2-email-was-read-interactively
                    (setq simplenote2-email nil))
                (if simplenote2-password-was-read-interactively
                    (setq simplenote2-password nil))
                (setq simplenote2-token nil)
                (error "Simplenote authentication failed"))
            (message "Simplenote authentication succeeded")
            (setq simplenote2-token (request-response-data res))))))))


;;; API calls for index and notes

(defun simplenote2-get-index-deferred (&optional index mark)
  "Get note index from server and returns the list of note index."
  (lexical-let ((index index)
                (mark mark))
    (deferred:$
      (simplenote2-get-token-deferred)
      (deferred:nextc it
        (lambda (token)
          (deferred:$
            (let ((params (list '("length" . "100")
                                (cons "auth" token)
                                (cons "email" simplenote2-email))))
              (when mark (push (cons "mark" mark) params))
              (request-deferred
               (concat simplenote2-server-url "api2/index")
               :type "GET"
               :params params
               :parser 'json-read))
            (deferred:nextc it
              (lambda (res)
                (if (request-response-error-thrown res)
                    (error "Could not retrieve index")
                  (mapc (lambda (e)
                          (unless (= (cdr (assq 'deleted e)) 1)
                            (push (cons (cdr (assq 'key e))
                                        (cdr (assq 'syncnum e))) index)))
                        (cdr (assq 'data (request-response-data res))))
                  (if (assq 'mark (request-response-data res))
                      (simplenote2-get-index-deferred
                       index
                       (cdr (assq 'mark (request-response-data res))))
                    index))))))))))

(defun simplenote2-get-note-deferred (key)
  (lexical-let ((key key))
    (deferred:$
      (simplenote2-get-token-deferred)
      (deferred:nextc it
        (lambda (token)
          (deferred:$
            (request-deferred
             (concat simplenote2-server-url "api2/data/" key)
             :type "GET"
             :params (list (cons "auth" token)
                           (cons "email" simplenote2-email))
             :parser 'json-read)
            (deferred:nextc it
              (lambda (res)
                (if (request-response-error-thrown res)
                    (message "Could not retreive note %s" key)
                  (simplenote2-save-note (request-response-data res)))))))))))

(defun simplenote2-mark-note-as-deleted-deferred (key)
  (lexical-let ((key key))
    (deferred:$
      (simplenote2-get-token-deferred)
      (deferred:nextc it
        (lambda (token)
          (deferred:$
            (request-deferred
             (concat simplenote2-server-url "api2/data/" key)
             :type "POST"
             :params (list (cons "auth" token)
                           (cons "email" simplenote2-email))
             :data (json-encode (list (cons "deleted" 1)))
             :parser 'json-read)
            (deferred:nextc it
              (lambda (res)
                (if (request-response-error-thrown res)
                    (progn (message "Could not delete note %s" key) nil)
                  (request-response-data res))))))))))

(defun simplenote2-update-note-deferred (key)
  (lexical-let ((key key)
                (note-info (gethash key simplenote2-notes-info)))
    (unless note-info
      (error "Could not find note info"))
    (deferred:$
      (simplenote2-get-token-deferred)
      (deferred:nextc it
        (lambda (token)
          (deferred:$
            (request-deferred
             (concat simplenote2-server-url "api2/data/" key)
             :type "POST"
             :params (list (cons "auth" token)
                           (cons "email" simplenote2-email))
             :data (json-encode
                    (list (cons "content" (simplenote2-get-file-string
                                           (simplenote2-filename-for-note key)))
                          (cons "version" (number-to-string (nth 1 note-info)))
                          (cons "modifydate"
                                (format "%.6f"
                                        (float-time
                                         (simplenote2-file-mtime
                                          (simplenote2-filename-for-note key)))))))
             :headers '(("Content-Type" . "application/json"))
             :parser 'json-read)
            (deferred:nextc it
              (lambda (res)
                (if (request-response-error-thrown res)
                    (progn (message "Could not update note %s" key) nil)
                  (simplenote2-save-note (request-response-data res)))))))))))

(defun simplenote2-create-note-deferred (file)
  (lexical-let ((file file)
                (content (simplenote2-get-file-string file))
                (createdate (format "%.6f" (float-time
                                            (simplenote2-file-mtime file)))))
    (deferred:$
      (simplenote2-get-token-deferred)
      (deferred:nextc it
        (lambda (token)
          (deferred:$
            (request-deferred
             (concat simplenote2-server-url "api2/data")
             :type "POST"
             :params (list (cons "auth" token)
                           (cons "email" simplenote2-email))
             :data (json-encode
                    (list (cons "content" content)
                          (cons "createdate" createdate)
                          (cons "modifydate" createdate)))
             :headers '(("Content-Type" . "application/json"))
             :parser 'json-read)
            (deferred:nextc it
              (lambda (res)
                (if (request-response-error-thrown res)
                    (progn (message "Could not create note") nil)
                  (let ((note (request-response-data res)))
                    (push (cons 'content content) note)
                    (simplenote2-save-note note)))))))))))


;;; Push and pull buffer as note

(defun simplenote2-push-buffer ()
  (interactive)
  (lexical-let ((file (buffer-file-name))
                (buf (current-buffer)))
    (cond
     ;; File is located on new notes directory
     ((string-match (simplenote2-new-notes-dir)
                    (file-name-directory file))
      (simplenote2-create-note-from-buffer))
     ;; File is located on notes directory
     ((string-match (simplenote2-notes-dir)
                    (file-name-directory file))
      (lexical-let* ((key (file-name-nondirectory file))
                     (note-info (gethash key simplenote2-notes-info)))
        (save-buffer)
        (if (and note-info
                 (time-less-p (seconds-to-time (nth 3 note-info))
                              (simplenote2-file-mtime file)))
            (deferred:$
              (simplenote2-update-note-deferred key)
              (deferred:nextc it
                (lambda (ret)
                  (if ret (progn
                            (message "Pushed note %s" key)
                            (when (eq buf (current-buffer))
                                  (revert-buffer nil t t))
                            (simplenote2-browser-refresh))
                    (message "Failed to push note %s" key)))))
          (message "No need to push this note"))))
     (t (message "Can't push buffer which isn't simplenote note")))))

;;;###autoload
(defun simplenote2-create-note-from-buffer ()
  (interactive)
  (lexical-let ((file (buffer-file-name))
                (buf (current-buffer)))
    (if (or (string= (simplenote2-notes-dir) (file-name-directory file))
            (not file))
        (message "Can't create note from this buffer")
      (save-buffer)
      (deferred:$
        (simplenote2-create-note-deferred file)
        (deferred:nextc it
          (lambda (key)
            (if (not key)
                (message "Failed to create note")
              (message "Created note %s" key)
              (simplenote2-open-note (simplenote2-filename-for-note key))
              (delete-file file)
              (kill-buffer buf)
              (simplenote2-browser-refresh))))))))

(defun simplenote2-pull-buffer ()
  (interactive)
  (lexical-let ((file (buffer-file-name))
                (buf (current-buffer)))
    (if (string= (simplenote2-notes-dir) (file-name-directory file))
        (lexical-let* ((key (file-name-nondirectory file))
                       (note-info (gethash key simplenote2-notes-info)))
          (if (and note-info
                   (time-less-p (seconds-to-time (nth 3 note-info))
                                (simplenote2-file-mtime file))
                   (y-or-n-p
                    "This note appears to have been modified. Do you push it on ahead?"))
              (simplenote2-push-buffer)
            (save-buffer)
            (deferred:$
              (simplenote2-get-note-deferred key)
              (deferred:nextc it
                (lambda (ret)
                  (when (eq buf (current-buffer))
                    (revert-buffer nil t t))
                  (simplenote2-browser-refresh))))))
      (message "Can't pull buffer which isn't simplenote note"))))


;;; Browser helper functions

(defun simplenote2-trash-dir ()
  (file-name-as-directory (concat (file-name-as-directory simplenote2-directory) "trash")))

(defun simplenote2-notes-dir ()
  (file-name-as-directory (concat (file-name-as-directory simplenote2-directory) "notes")))

(defun simplenote2-new-notes-dir ()
  (file-name-as-directory (concat (file-name-as-directory simplenote2-directory) "new")))

;;;###autoload
(defun simplenote2-setup ()
  (interactive)
  (simplenote2-load-notes-info)
  (add-hook 'kill-emacs-hook 'simplenote2-save-notes-info)
  (when (not (file-exists-p simplenote2-directory))
    (make-directory simplenote2-directory t))
  (when (not (file-exists-p (simplenote2-notes-dir)))
    (make-directory (simplenote2-notes-dir) t))
  (when (not (file-exists-p (simplenote2-trash-dir)))
    (make-directory (simplenote2-trash-dir) t))
  (when (not (file-exists-p (simplenote2-new-notes-dir)))
    (make-directory (simplenote2-new-notes-dir) t)))

(defun simplenote2-filename-for-note (key)
  (concat (simplenote2-notes-dir) key))

(defun simplenote2-filename-for-note-marked-deleted (key)
  (concat (simplenote2-trash-dir) key))

(defun simplenote2-note-headline (text)
  "The first non-empty line of a note."
  (let ((begin (string-match "^.+$" text)))
    (when begin
      (substring text begin (min (match-end 0)
                                 (+ begin simplenote2-note-head-size))))))

(defun simplenote2-note-headrest (text)
  "Text after the first non-empty line of a note, to fill in the list display."
  (let* ((headline (simplenote2-note-headline text))
         (text (replace-regexp-in-string "\n" " " text))
         (begin (when headline (string-match (regexp-quote headline) text))))
    (when begin
      (truncate-string-to-width (substring text (match-end 0)) (- simplenote2-note-head-size (string-width headline))))))

(defun simplenote2-open-note (file)
  "Opens FILE in a new buffer, setting its mode, and returns the buffer.

The major mode of the resulting buffer will be set to
`simplenote2-notes-mode' but can be overridden by a file-local
setting."
  (prog1 (find-file file)
    ;; Don't switch mode when set via file cookie
    (when (eq major-mode (default-value 'major-mode))
      (funcall simplenote2-notes-mode))
    ;; Refresh notes display after save
    (add-hook 'after-save-hook
              (lambda () (save-excursion (simplenote2-browser-refresh)))
              nil t)))


;; Simplenote sync

(defun simplenote2-sync-notes (&optional arg)
  (interactive "P")
  (lexical-let ((arg arg))
    (deferred:$
      ;; Step1: Sync update on local
      (deferred:parallel
        (list
         ;; Step1-1: Delete notes locally marked as deleted.
         (deferred:$
           (deferred:parallel
             (mapcar (lambda (file)
                       (lexical-let* ((file file)
                                      (key (file-name-nondirectory file)))
                         (deferred:$
                           (simplenote2-mark-note-as-deleted-deferred key)
                           (deferred:nextc it
                             (lambda (ret) (when ret
                                             (message "Deleted on local: %s" key)
                                             (remhash key simplenote2-notes-info)
                                             (let ((buf (get-file-buffer file)))
                                               (when buf (kill-buffer buf)))
                                             (delete-file file)))))))
                     (directory-files (simplenote2-trash-dir) t "^[a-zA-Z0-9_\\-]+$")))
           (deferred:nextc it (lambda () nil)))
         ;; Step1-2: Push notes locally created
         (deferred:$
           (deferred:parallel
             (mapcar (lambda (file)
                       (lexical-let ((file file))
                         (deferred:$
                           (simplenote2-create-note-deferred file)
                           (deferred:nextc it
                             (lambda (key) (when key
                                             (message "Created on local: %s" key)
                                             (let ((buf (get-file-buffer file)))
                                               (when buf (kill-buffer buf)))
                                             (delete-file file)))))))
                     (directory-files (simplenote2-new-notes-dir) t "^note-[0-9]+$")))
           (deferred:nextc it (lambda () nil)))
         ;; Step1-3: Push notes locally modified
         (deferred:$
           (let (keys-to-push)
             (dolist (file (directory-files
                            (simplenote2-notes-dir) t "^[a-zA-Z0-9_\\-]+$"))
               (let* ((key (file-name-nondirectory file))
                      (note-info (gethash key simplenote2-notes-info)))
                 (when (and note-info
                            (time-less-p (seconds-to-time (nth 3 note-info))
                                         (simplenote2-file-mtime file)))
                   (push key keys-to-push))))
             (deferred:$
               (deferred:parallel
                 (mapcar (lambda (key)
                           (deferred:$
                             (simplenote2-update-note-deferred key)
                             (deferred:nextc it
                               (lambda (ret)
                                 (when (eq ret key)
                                   (message "Updated on local: %s" key))))))
                         keys-to-push))
               (deferred:nextc it (lambda () nil)))))))
      ;; Step2: Sync update on server
      (deferred:nextc it
        (lambda ()
          ;; Step2-1: Get index from server and update local files.
          (deferred:$
            (simplenote2-get-index-deferred)
            (deferred:nextc it
              (lambda (index)
                ;; Step2-2: Delete notes on local which are not included in the index.
                (let ((keys-in-index (mapcar (lambda (e) (car e)) index)))
                  (dolist (file (directory-files
                                 (simplenote2-notes-dir) t "^[a-zA-Z0-9_\\-]+$"))
                    (let ((key (file-name-nondirectory file)))
                      (unless (member key keys-in-index)
                        (message "Deleted on server: %s" key)
                        (remhash key simplenote2-notes-info)
                        (let ((buf (get-file-buffer file)))
                          (when buf (kill-buffer buf)))
                        (delete-file file)))))
                ;; Step2-3: Update notes on local which are older than that on server.
                (let (keys-to-update)
                  (if (not arg)
                      (dolist (elem index)
                        (let* ((key (car elem))
                               (note-info (gethash key simplenote2-notes-info)))
                          ;; Compare syncnum on server and local data.
                          ;; If the note information isn't found, the note would be a
                          ;; newly created note on server.
                          (when (< (if note-info (nth 0 note-info) 0) (cdr elem))
                            (message "Updated on server: %s" key)
                            (push key keys-to-update))))
                    (setq keys-to-update (mapcar (lambda (e) (car e)) index)))
                  (deferred:$
                    (deferred:parallel
                      (mapcar (lambda (key) (simplenote2-get-note-deferred key))
                              keys-to-update))
                    (deferred:nextc it
                      (lambda (notes)
                        (message "Syncing all notes done")
                        (simplenote2-save-notes-info)
                        ;; Refresh the browser
                        (save-excursion
                          (simplenote2-browser-refresh))))))))))))))


;;; Simplenote browser

(defvar simplenote2-mode-map
  (let ((map (copy-keymap widget-keymap)))
    (define-key map (kbd "g") 'simplenote2-sync-notes)
    (define-key map (kbd "q") 'quit-window)
    map))

(defun simplenote2-mode ()
  "Browse and edit Simplenote notes locally and sync with the server.

\\{simplenote2-mode-map}"
  (kill-all-local-variables)
  (setq buffer-read-only t)
  (use-local-map simplenote2-mode-map)
  (simplenote2-menu-setup)
  (setq major-mode 'simplenote2-mode
        mode-name "Simplenote")
  (run-mode-hooks 'simplenote2-mode-hook))

;;;###autoload
(defun simplenote2-browse ()
  (interactive)
  (when (not (file-exists-p simplenote2-directory))
      (make-directory simplenote2-directory t))
  (switch-to-buffer "*Simplenote*")
  (simplenote2-mode)
  (goto-char 1))

(defun simplenote2-browser-refresh ()
  (interactive)
  (when (get-buffer "*Simplenote*")
    (set-buffer "*Simplenote*")
    (simplenote2-menu-setup)))


(defun simplenote2-menu-setup ()
  (let ((inhibit-read-only t))
    (erase-buffer))
  (remove-overlays)
  ;; Buttons
  (widget-create 'link
                 :format "%[%v%]"
                 :help-echo "Synchronize with the Simplenote server"
                 :notify (lambda (widget &rest ignore)
                           (simplenote2-sync-notes)
                           (simplenote2-browser-refresh))
                 "Sync with server")
  (widget-insert "  ")
  (widget-create 'link
                 :format "%[%v%]"
                 :help-echo "Create a new note"
                 :notify (lambda (widget &rest ignore)
                           (let (buf)
                             (setq buf (simplenote2-create-note-locally))
                             (simplenote2-browser-refresh)
                             (switch-to-buffer buf)))
                 "Create new note")
  (widget-insert "\n\n")
  ;; New notes list
  (let ((new-notes (directory-files (simplenote2-new-notes-dir) t "^note-[0-9]+$")))
    (when new-notes
      (widget-insert "== NEW NOTES\n\n")
      (mapc 'simplenote2-new-note-widget new-notes)))
  ;; Other notes list
  (let (files)
    (setq files (append
                 (mapcar (lambda (file) (cons file nil))
                         (directory-files (simplenote2-notes-dir) t "^[a-zA-Z0-9_\\-]+$"))
                 (mapcar (lambda (file) (cons file t))
                         (directory-files (simplenote2-trash-dir) t "^[a-zA-Z0-9_\\-]+$"))))
    (when files
      (setq files (sort files (lambda (p1 p2) (simplenote2-file-newer-p (car p1) (car p2)))))
      (setq files (sort files (lambda (p1 p2) (simplenote2-pinned-note-p (car p1) (car p2)))))
      (widget-insert "== NOTES")
      (dolist (tag simplenote2-filter-note-tag-list)
        (widget-insert (format " [%s]" tag)))
      (widget-insert "\n\n")
      (dolist (file files)
        (let ((note-info (gethash (file-name-nondirectory (car file))
                                  simplenote2-notes-info)))
          (when (or (not simplenote2-filter-note-tag-list)
                    (loop for tag in simplenote2-filter-note-tag-list
                          when (simplenote2-tag-existp tag (nth 4 note-info))
                          collect tag))
            (simplenote2-other-note-widget file))))))
  (use-local-map simplenote2-mode-map)
  (widget-setup))

(defun simplenote2-filter-note-by-tag (&optional arg)
  (interactive "P")
  (setq simplenote2-filter-note-tag-list nil)
  (when (not arg)
    (let (tag)
      (setq tag (read-string "Input tag: "))
      (while (not (string= tag ""))
        (push tag simplenote2-filter-note-tag-list)
        (setq tag (read-string "Input tag: ")))))
  (simplenote2-browser-refresh))

(defun simplenote2-file-newer-p (file1 file2)
  (let (time1 time2)
    (setq time1 (nth 5 (file-attributes file1)))
    (setq time2 (nth 5 (file-attributes file2)))
    (time-less-p time2 time1)))

(defun simplenote2-pinned-note-p (file1 file2)
  (and (nth 6 (gethash (file-name-nondirectory file1) simplenote2-notes-info))
       (not (nth 6 (gethash (file-name-nondirectory file2) simplenote2-notes-info)))))

(defun simplenote2-new-note-widget (file)
  (let* ((modify (nth 5 (file-attributes file)))
         (modify-string (format-time-string "%Y-%m-%d %H:%M:%S" modify))
         (note (simplenote2-get-file-string file))
         (headline (simplenote2-note-headline note))
         (shorttext (simplenote2-note-headrest note)))
    (widget-create 'link
                   :button-prefix ""
                   :button-suffix ""
                   :format "%[%v%]"
                   :tag file
                   :help-echo "Edit this note"
                   :notify (lambda (widget &rest ignore)
                             (simplenote2-open-note (widget-get widget :tag)))
                   headline)
    (widget-insert shorttext "\n")
    (widget-insert "  " modify-string "\t                                      \t")
    (widget-create 'link
                   :tag file
                   :value "Edit"
                   :format "%[%v%]"
                   :help-echo "Edit this note"
                   :notify (lambda (widget &rest ignore)
                             (simplenote2-open-note (widget-get widget :tag)))
                    "Edit")
    (widget-insert " ")
    (widget-create 'link
                   :format "%[%v%]"
                   :tag file
                   :help-echo "Permanently remove this file"
                   :notify (lambda (widget &rest ignore)
                             (let ((file (widget-get widget :tag)))
                               (delete-file file)
                               (let ((buf (get-file-buffer file)))
                                 (when buf (kill-buffer buf)))
                               (simplenote2-browser-refresh)))
                   "Remove")
    (widget-insert "\n\n")))

(defun simplenote2-other-note-widget (pair)
  (let* ((file (car pair))
         (deleted (cdr pair))
         (key (file-name-nondirectory file))
         (modify (nth 5 (file-attributes file)))
         (modify-string (format-time-string "%Y-%m-%d %H:%M:%S" modify))
         (note (simplenote2-get-file-string file))
         (note-info (gethash key simplenote2-notes-info))
         (headline (simplenote2-note-headline note))
         (shorttext (simplenote2-note-headrest note)))
    (when (nth 6 note-info) (widget-insert "*"))
    (widget-create 'link
                   :button-prefix ""
                   :button-suffix ""
                   :format "%[%v%]"
                   :tag file
                   :help-echo "Edit this note"
                   :notify (lambda (widget &rest ignore)
                             (simplenote2-open-note (widget-get widget :tag)))
                   headline)
    (widget-insert shorttext "\n")
    (if simplenote2-show-note-file-name
      (widget-insert "  " modify-string "\t" (propertize key 'face 'shadow) "\t")
      (widget-insert "  " modify-string "\t"))
    (widget-create 'link
                   :tag file
                   :value "Edit"
                   :format "%[%v%]"
                   :help-echo "Edit this note"
                   :notify (lambda (widget &rest ignore)
                             (simplenote2-open-note (widget-get widget :tag)))
                    "Edit")
    (widget-insert " ")
    (widget-create 'link
                   :format "%[%v%]"
                   :tag key
                   :help-echo (if deleted
                                  "Mark this note as not deleted"
                                "Mark this note as deleted")
                   :notify (if deleted
                               simplenote2-undelete-me
                             simplenote2-delete-me)
                   (if deleted
                       "Undelete"
                     "Delete"))
    (widget-insert "\n    ")
    (let ((tags (nth 4 note-info)))
      (loop for i from 0 below (length tags) do
            (widget-insert (format "[%s] "(aref tags i)))))
    (widget-insert "\n")))

(setq simplenote2-delete-me
      (lambda (widget &rest ignore)
        (simplenote2-mark-note-for-deletion (widget-get widget :tag))
        (widget-put widget :notify simplenote2-undelete-me)
        (widget-value-set widget "Undelete")
        (widget-setup)))

(setq simplenote2-undelete-me
  (lambda (widget &rest ignore)
    (simplenote2-unmark-note-for-deletion (widget-get widget :tag))
    (widget-put widget :notify simplenote2-delete-me)
    (widget-value-set widget "Delete")
    (widget-setup)))

(defun simplenote2-mark-note-for-deletion (key)
  (rename-file (simplenote2-filename-for-note key)
               (simplenote2-filename-for-note-marked-deleted key)))

(defun simplenote2-unmark-note-for-deletion (key)
  (rename-file (simplenote2-filename-for-note-marked-deleted key)
               (simplenote2-filename-for-note key)))

(defun simplenote2-create-note-locally ()
  (let (new-filename counter)
    (setq counter 0)
    (setq new-filename (concat (simplenote2-new-notes-dir) (format "note-%d" counter)))
    (while (file-exists-p new-filename)
      (setq counter (1+ counter))
      (setq new-filename (concat (simplenote2-new-notes-dir) (format "note-%d" counter))))
    (write-region "New note" nil new-filename nil)
    (simplenote2-browser-refresh)
    (simplenote2-open-note new-filename)))


(provide 'simplenote2)

;;; simplenote2.el ends here
