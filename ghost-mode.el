;;; ghost-mode.el --- A mode to manage Ghost blog
;;

;; Author: Javier Aguirre <hello@javaguirre.net>
;; Maintainer: Javier Aguirre <hello@javaguirre.net>
;; Version: 0.1
;; Package-Requires: ((markdown-mode "1.0"))
;; Created: 10 Feb 2016
;; Keywords: ghost, blog
;; URL: https://github.com/javaguirre/ghost-mode

;;; Commentary:

;; This is a minor mode to manage Ghost blogs
;; through their Rest API.Ghost Rest API only permits
;; reading now.This package has the option of reading
;; posts and openning them.Edit and create post is implemented
;; but doesn't work until the Ghost team opens that part of the API

;;; Code:
;;
(require 'url)
(require 'json)
(require 'markdown-mode)
(eval-when-compile (require 'cl))

(defvar ghost-mode-url nil)
(defvar ghost-mode-bearer-token nil)
(defvar ghost-mode-post-list-limit 10)

(defvar ghost-mode-post-list-header-title "Ghost mode - Posts\n\n")
(defvar ghost-mode-post-endpoint "/posts/")
(defvar ghost-mode-buffer-post-name "ghost-post.md")

;; Metadata
(defvar ghost-mode-metadata-default-header-string
  "---\n\ntitle: New title\nslug: /new-title\n\n---\n\nNew post")
(defvar ghost-mode--metadata-prefix "---\n\n")
(defvar ghost-mode--metadata-suffix "\n---\n\n")
(defvar ghost-mode--metadata-field-separator ": ")

;; Fields
(defvar ghost-mode-default-metadata-fields
  '(title slug status image featured page language meta_title meta_description))
(defvar ghost-mode-required-metadata-fields
  '(title markdown))

;; Messages
(defvar ghost-mode-http-authentication-warning-message
  "Authentication failed, you need to set ghost-mode-url and ghost-mode-bearer-token")
(defvar
  ghost-mode--invalid-metadata-message
  "Error in metadata, you need to set the title")
(defvar ghost-mode--update-post-message "Post updated successfully!")
(defvar ghost-mode--create-post-message "Post created successfully!")
(defvar
  ghost-mode--persist-post-failed
  "Post persist failed, please check if your credentials are well set")

(defvar ghost-mode--date-format-string "%d-%m-%Y")
;;;###autoload
;;; Commands
(defun ghost-mode-new-post ()
  "Create new post template."
  (interactive)

  (ghost-mode--use-ghost-post-buffer
   ghost-mode-metadata-default-header-string))

(defun ghost-mode-save-new-post ()
  "Create new post."
  (interactive)

  (let* ((json-object-type 'hash-table)
	 (data (json-encode (ghost-mode--read-from-post-buffer))))
    (if (ghost-mode--is-metadata-valid metadata)
        (ghost-mode--connection
         (ghost-mode--get-post-list-endpoint)
         'ghost-mode--create-post-callback
         "POST"
         data)
      (message ghost-mode--invalid-metadata-message))))

(defun ghost-mode-update-post ()
  "Update a post."
  (interactive)

  (let* ((json-object-type 'hash-table)
	 (metadata (ghost-mode--read-from-post-buffer))
	 (payload (json-encode metadata)))
    (if (ghost-mode--is-metadata-valid metadata)
	(ghost-mode--connection
	 (concat ghost-mode-post-endpoint (gethash "id" metadata))
	 'ghost-mode--update-post-callback
	 "PUT"
	 payload)
      (message ghost-mode--invalid-metadata-message))))

(defun ghost-mode-get-posts ()
  "Get posts from ghost."
  (interactive)
  (ghost-mode--connection ghost-mode-post-endpoint 'ghost-mode--get-posts-callback))

;; Advice
(defadvice url-http-handle-authentication (around ghost-mode-get-posts)
  "Advice for url.el http authentication."
  (message ghost-mode-http-authentication-warning-message))
(ad-activate 'url-http-handle-authentication)

(defun ghost-mode--connection (endpoint callback &optional method data)
  "HTTP Connection with Ghost API using ENDPOINT, execute CALLBACK.  METHOD and DATA can be set."
  (let ((url-request-method (or method "GET"))
	(url-request-extra-headers
	 `(("Authorization" . ,ghost-mode-bearer-token))))
    (url-retrieve (concat ghost-mode-url endpoint) callback)))

;; Callbacks
(defun ghost-mode--create-post-callback (status)
  "Process post creation, receive HTTP response STATUS."
  (if (ghost-mode--is-request-successful)
      (message ghost-mode--create-post-message)
    (message ghost-mode--persist-post-failed)))

(defun ghost-mode--update-post-callback (status)
  "Process post update, receive HTTP response STATUS."
  (if (ghost-mode--is-request-successful)
      (message ghost-mode--update-post-message)
    (message ghost-mode--persist-post-failed)))

(defun ghost-mode--get-posts-callback (status)
  "Process post list callback, receive HTTP response STATUS."
  (ghost-mode--go-to-body)

  (let ((posts (ghost-mode--get-response-posts)))
    (define-button-type 'ghost-show-post-button
      'action 'ghost-mode--show-post-action
      'follow-link t
      'help-echo "Show post")

    (erase-buffer)

    (insert ghost-mode-post-list-header-title)

    (dotimes (i (length posts))

      (insert-text-button (format "%d %s - %s\n\n"
				  (gethash "id" (aref posts i))
				  (ghost-mode--format-date
				   (gethash "created_at" (aref posts i)))
				  (gethash "title" (aref posts i)))
			  :type 'ghost-show-post-button))))

(defun ghost-mode--get-post-callback (status)
  "Process post read callback, receive HTTP response STATUS."
  (ghost-mode--go-to-body)

  (let* ((posts (ghost-mode--get-response-posts))
	 (current-post (aref posts 0)))
    (ghost-mode--use-ghost-post-buffer
     (format "%s%s"
	     (ghost-mode--get-metadata-as-string current-post)
	     (gethash "markdown" current-post)))))

;; Metadata
(defun ghost-mode--get-metadata-as-string (post)
  "Get list of POST metadata as a string."
  (let ((metadata ghost-mode--metadata-prefix))
    (dolist (metadata-field ghost-mode-default-metadata-fields)
      (setq current-value (gethash (symbol-name metadata-field) post))

      (if (not (stringp current-value))
	  (setq current-value ""))

    (setq metadata
	(concat metadata
		(symbol-name metadata-field)
		ghost-mode--metadata-field-separator
		current-value
		"\n")))
    (setq metadata (concat metadata ghost-mode--metadata-suffix))
    metadata))

(defun ghost-mode--get-metadata-as-hash-table (metadata)
  "Get list of metadata as a hash table from a METADATA string."
  (let* ((items (split-string metadata "\n"))
	 (post (make-hash-table :test 'equal))
	 (current-item nil))
    (dolist (item items)
      (setq current-item (split-string item ": "))

      (if (and (> (length (car current-item)) 0)
	       (member (intern (car current-item)) ghost-mode-default-metadata-fields))
	  (puthash (car current-item) (cadr current-item) post)))
    post))

(defun ghost-mode--is-metadata-valid (metadata)
  "Validate METADATA."
  (let ((is-valid t))
    (dolist (required-metadata-field ghost-mode-required-metadata-fields)
      (unless (gethash (symbol-name required-metadata-field) metadata)
	(setq is-valid nil)))
    is-valid))

;; Utils
(defun ghost-mode--use-ghost-post-buffer (buffer-data)
  "Use ghost post buffer and insert BUFFER-DATA on It."
  (let ((post-buffer ghost-mode-buffer-post-name))
    (get-buffer-create post-buffer)
    (switch-to-buffer post-buffer)
    (erase-buffer)
    (insert buffer-data)
    (markdown-mode)))

(defun ghost-mode--read-from-post-buffer ()
  "Read from current post buffer and transform It to hash-table."
  (let* ((metadata-start (string-match ghost-mode--metadata-prefix (buffer-string)))
	 (metadata-end (string-match ghost-mode--metadata-suffix (buffer-string)))
	 (metadata
	  (substring
	   (buffer-string)
	   (+ metadata-start (length ghost-mode--metadata-prefix))
	   metadata-end))
	 (markdown
	  (substring
	   (buffer-string)
	   (+ metadata-end (length ghost-mode--metadata-suffix))
	   (- (point-max) 1)))
	 (post nil))
    (setq post (ghost-mode--get-metadata-as-hash-table metadata))
    (puthash "markdown" markdown post)
    post))

(defun ghost-mode--show-post-action (button)
  "Show a post by id from BUTTON."
  (let* ((id (car (split-string (button-label button))))
	 (endpoint (concat "/posts/" id)))
    (ghost-mode--connection endpoint 'ghost-mode--get-post-callback)))

(defun ghost-mode--get-http-status-code ()
  "Get the HTTP status of the current request."
  (switch-to-buffer (current-buffer))

  (let* ((http-status-length 3)
	 (start-point (re-search-forward "\\s-")))
	 (buffer-substring start-point (+ start-point http-status-length))))

(defun ghost-mode--go-to-body ()
  "Go to HTTP response body."
  (switch-to-buffer (current-buffer))
  (search-forward "\n\n")
  (delete-region (point-min) (point)))

(defun ghost-mode--get-response-posts ()
  "Get posts from HTTP response body."
  (let ((body (ghost-mode--get-response-body)))
    (gethash "posts" body)))

(defun ghost-mode--get-response-body ()
  "Get HTTP response body json decoded."
  (let ((json-object-type 'hash-table))
    (json-read-from-string (buffer-string))))

(defun ghost-mode--is-request-successful ()
  "Check if the request has a successful http status."
  (let ((ghost-mode--http-ok "200"))
   (= (ghost-mode--get-http-status-code) ghost-mode--http-ok)))

(defun ghost-mode--format-date (date)
  "Get friendlier date format from DATE."
  (format-time-string
   ghost-mode--date-format-string
   (date-to-time date)))

;; Endpoints

(defun ghost-mode--get-post-list-endpoint ()
  "Get the post list endpoint."
  (let ((limit (or ghost-mode-post-list-limit "")))
    (if limit (setq limit (format "?limit=%d" limit)))
    (concat ghost-mode-post-endpoint limit)))

(provide 'ghost-mode)
;;; ghost-mode.el ends here
