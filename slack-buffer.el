;;; slack-buffer.el --- slack buffer                  -*- lexical-binding: t; -*-

;; Copyright (C) 2015  南優也

;; Author: 南優也 <yuyaminami@minamiyuunari-no-MacBook-Pro.local>
;; Keywords:

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

;;; Code:

(require 'eieio)
(require 'lui)
(require 'slack-room)

(defvar lui-prompt-string "> ")

(defvar slack-mode-map
  (let ((map (make-sparse-keymap)))
    ;; (define-key map (kbd "C-s C-r") #'slack-room-update-messages)
    ;; (define-key map (kbd "C-s C-b") #'slack-message-write-another-buffer)
    map))

(defcustom slack-default-directory
  (expand-file-name (concat (or (getenv "HOME") "~") "/"))
  "default directory at Slack Buffer.")

(define-derived-mode slack-mode lui-mode "Slack"
  ""
  (setq-local default-directory slack-default-directory)
  (lui-set-prompt lui-prompt-string)
  (setq lui-input-function 'slack-message--send))

(define-derived-mode slack-info-mode lui-mode "Slack Info"
  ""
  (setq-local default-directory slack-default-directory)
  (lui-set-prompt lui-prompt-string))

(defvar slack-current-room-id)

(defvar slack-current-team-id)

(defvar slack-current-message nil)

(defcustom slack-buffer-emojify nil
  "Show emoji with `emojify' if true."
  :group 'slack)

(defcustom slack-buffer-create-on-notify nil
  "Create a room buffer when notification received if it does not yet exist"
  :group 'slack)

(defmacro slack-buffer-widen (&rest body)
  `(save-excursion
     (save-restriction
       (widen)
       ,@body)))

(defun slack-get-buffer-create (room)
  (let* ((buf-name (slack-room-buffer-name room))
         (buffer (get-buffer buf-name)))
    (unless buffer
      (setq buffer (generate-new-buffer buf-name))
      (slack-room-setup-buffer room buffer)
      (slack-room-set-buffer room buffer))
    buffer))

(defmethod slack-buffer-set-current-room-id ((room slack-room))
  (set (make-local-variable 'slack-current-room-id) (oref room id)))

(defun slack-buffer-set-current-team-id (team)
  (set (make-local-variable 'slack-current-team-id) (oref team id)))

(defun slack-buffer-enable-emojify ()
  (if slack-buffer-emojify
      (let ((emojify (require 'emojify nil t)))
        (unless emojify
          (error "Emojify is not installed"))
        (emojify-mode t))))

(defun slack-buffer-goto (ts)
  (let ((point (slack-buffer-ts-eq (point-min) (point-max) ts)))
    (when point
      (goto-char point))))

(cl-defun slack-buffer-create (room team)
  (let ((buffer (slack-get-buffer-create room)))
    (with-current-buffer buffer
      (slack-buffer-set-current-room-id room)
      (slack-buffer-set-current-team-id team)
      (slack-buffer-enable-emojify))
    buffer))

(defun slack-buffer-buttonize-link ()
  (let ((regex "<\\(http://\\|https://\\)\\(.*?\\)|\\(.*?\\)>"))
    (ignore-errors (while (re-search-forward regex nil t)
      (let ((url-begin (match-beginning 1))
            (url (concat (match-string 1) (match-string 2)))
            (replace (match-string 3)))
        (replace-match replace nil)

        (make-button (1- url-begin)
                     (+ (1- url-begin) (length replace))
                     'type 'lui-button
                     'action 'lui-button-activate
                     'lui-button-function 'browse-url
                     'lui-button-arguments (list url)))))))

(defun slack-buffer-insert (message team &optional not-tracked-p)
  (let ((lui-time-stamp-time (slack-message-time-stamp message))
        (beg lui-input-marker)
        (inhibit-read-only t))
    (let ((slack-current-message message))
      (lui-insert-with-text-properties
       (slack-message-to-string message team)
       'not-tracked-p not-tracked-p
       'ts (oref message ts)
       'slack-last-ts lui-time-stamp-last))))

(defun slack-buffer-show-typing-p (buffer)
  (cl-case slack-typing-visibility
    ('frame (slack-buffer-in-current-frame buffer))
    ('buffer (slack-buffer-current-p buffer))
    ('never nil)))

(defun slack-buffer-current-p (buffer)
  (if buffer
      (string= (buffer-name buffer)
               (buffer-name (current-buffer)))))

(defun slack-buffer-in-current-frame (buffer)
  (if buffer
      (cl-member (buffer-name buffer)
                 (mapcar #'buffer-name
                         (mapcar #'window-buffer (window-list)))
                 :test #'string=)))

(cl-defun slack-buffer-update (room msg team &key replace)
  (let* ((buf-name (slack-room-buffer-name room))
         (buffer (get-buffer buf-name)))
    (if buffer
        (progn
          (slack-room-update-last-read room msg)
          (if (slack-buffer-in-current-frame buffer)
              (slack-room-update-mark room team msg)
            (slack-room-inc-unread-count room))
          (if replace (slack-buffer-replace buffer msg)
            (with-current-buffer buffer (slack-buffer-insert msg team))))
      (slack-room-inc-unread-count room)
      (and slack-buffer-create-on-notify
           (slack-room-create-buffer-bg room team)))))

(defmacro slack-buffer-goto-char (find-point &rest else)
  `(let* ((cur-point (point))
          (ts (get-text-property cur-point 'ts)))
     (let ((next-point ,find-point))
       (if next-point
           (goto-char next-point)
         (if (< 0 (length ',else))
             ,@else)))))

(defun slack-buffer-goto-next-message ()
  (interactive)
  (slack-buffer-goto-char
   (slack-buffer-next-point cur-point (point-max) ts)
   (slack-buffer-goto-first-message))
  (recenter))

(defun slack-buffer-goto-prev-message ()
  (interactive)
  (slack-buffer-goto-char
   (slack-buffer-prev-point cur-point (point-min) ts)
   (slack-buffer-goto-last-message))
  (recenter))

(defun slack-buffer-goto-first-message ()
  (interactive)
  (goto-char
   (slack-buffer-next-point (point-min) (point-max) "0")))

(defun slack-buffer-goto-last-message ()
  (interactive)
  (goto-char
   (slack-buffer-prev-point (point-max) (point-min) (format-time-string "%s"))))

(defun slack-buffer-header-p (point)
  (let ((face (get-text-property point 'face)))
    (string= (format "%s" face) "slack-message-output-header")))

(defun slack-buffer-next-point (start end ts)
  (cl-loop for i from start to end
           if (and (string< ts
                            (get-text-property i 'ts))
                   (slack-buffer-header-p i))
           return i))

(defun slack-buffer-prev-point (start end ts)
  (cl-loop for i from start downto end
           if (and (string< (get-text-property i 'ts)
                            ts)
                   (slack-buffer-header-p i))
           return i))

(defun slack-buffer-ts-eq (start end ts)
  (if (and start end)
      (cl-loop for i from start to end
               if (string= (get-text-property i 'ts)
                           ts)
               return i)))

(defun slack-buffer-replace (buffer msg)
  (with-current-buffer buffer
    (slack-buffer-widen
     (let ((team (slack-team-find slack-current-team-id)))
       (lui-replace (slack-message-to-string msg team)
                    (lambda ()
                      (equal (get-text-property (point) 'ts)
                             (oref msg ts))))))))

(defun slack-buffer-create-info (buf-name insert-func)
  (let ((buf (or (get-buffer buf-name)
                 (generate-new-buffer buf-name))))
    (with-current-buffer buf
      (setq buffer-read-only nil)
      (erase-buffer)
      (goto-char (point-min))
      (funcall insert-func)
      (goto-char (point-max))
      (setq buffer-read-only t)
      (slack-buffer-enable-emojify))
    buf))

(defun slack-buffer-delete-message (buf-name ts)
  (let ((buf (get-buffer buf-name)))
    (and buf
         (with-current-buffer buf
           (lui-delete (lambda () (equal (get-text-property (point) 'ts)
                                         ts)))))))

(provide 'slack-buffer)
;;; slack-buffer.el ends here
