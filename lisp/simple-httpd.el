;;; simple-httpd.el --- pure elisp HTTP server

;; This is free and unencumbered software released into the public domain.

;; Author: Christopher Wellons <mosquitopsu@gmail.com>
;; URL: https://github.com/skeeto/emacs-http-server
;; Version: 1.2.4

;;; Commentary:

;; Use `httpd-start' to start the web server. Files are served from
;; `httpd-root' on port `httpd-port'. While the root can be changed at
;; any time, the server needs to be restarted in order for a port
;; change to take effect.

;; Everything is performed by servlets, including serving
;; files. Servlets are enabled by setting `httpd-servlets' to true
;; (default). Servlets are four-parameter functions that begin with
;; "httpd/" where the trailing component specifies the initial path on
;; the server. For example, the function `httpd/hello-world' will be
;; called for the request "/hello-world" and "/hello-world/foo".

;; The default servlet `httpd/' is the one that serves files from
;; `httpd-root' and can be turned off through redefinition or setting
;; `httpd-serve-files' to nil. It is used even when `httpd-servlets'
;; is nil.

;; The four parameters for a servlet are process, URI path, GET/POST
;; arguments (alist), and the full request object (header
;; alist). These are ordered by general importance so that some can be
;; ignored. Two macros are provided to help with writing servlets.

;;  * `with-httpd-buffer' -- Creates a temporary buffer that is
;;    automatically served to the client at the end of the body. For
;;    example, this servlet says hello,

;;     (defun httpd/hello-world (proc path &rest args)
;;       (with-httpd-buffer proc "text/plain"
;;         (insert "hello, " (file-name-nondirectory path))))

;; This servlet be viewed at http://localhost:8080/hello-world/Emacs

;; * `defservlet' -- Similar to the above macro but totally hides the
;;   process object from the servlet itself. The above servlet can be
;;   re-written identically like so,

;;     (defservlet hello-world text/plain (path)
;;       (insert "hello, " (file-name-nondirectory path)))

;; The "function parameters" part can be left empty or contain up to
;; three parameters corresponding to the final three servlet
;; parameters. For example, a servlet that shows *scratch* and doesn't
;; need parameters,

;;     (defservlet scratch text/plain ()
;;       (insert-buffer-substring (get-buffer-create "*scratch*")))

;; Some support functions are available for servlets (but *not* for
;; use within a `defservlet' or `with-httpd-buffer').

;;   * `httpd-send-file'   -- serve a file with proper caching
;;   * `httpd-redirect'    -- redirect the browser to another url
;;   * `httpd-send-header' -- send custom headers
;;   * `httpd-error'       -- report an error to the client
;;   * `httpd-log'         -- log an object to *httpd*

;;; Code:

(require 'cl)
(require 'pp)
(require 'url-util)

(defgroup simple-httpd nil
  "A simple web server."
  :group 'comm)

(defcustom httpd-port 8080
  "Web server port."
  :group 'simple-httpd
  :type 'integer)

(defcustom httpd-root "~/public_html"
  "Web server file root."
  :group 'simple-httpd
  :type 'directory)

(defcustom httpd-serve-files t
  "Enable serving files from httpd-root."
  :group 'simple-httpd
  :type 'boolean)

(defcustom httpd-listings t
  "If true, serve directory listings."
  :group 'simple-httpd
  :type 'boolean)

(defcustom httpd-servlets t
  "Enable servlets."
  :group 'simple-httpd
  :type 'boolean)

(defcustom httpd-start-hook nil
  "Hook to run when the server has started."
  :group 'simple-httpd
  :type 'hook)

(defcustom httpd-stop-hook nil
  "Hook to run when the server has stopped."
  :group 'simple-httpd
  :type 'hook)

(defvar httpd-server-name (format "simple-httpd (Emacs %s)" emacs-version)
  "String to use in the Server header.")

(defvar httpd-mime-types
  '(("png"  . "image/png")
    ("gif"  . "image/gif")
    ("jpg"  . "image/jpeg")
    ("jpeg" . "image/jpeg")
    ("tif"  . "image/tif")
    ("tiff" . "image/tiff")
    ("ico"  . "image/x-icon")
    ("svg"  . "image/svg+xml")
    ("css"  . "text/css")
    ("htm"  . "text/html")
    ("html" . "text/html")
    ("xml"  . "text/xml")
    ("txt"  . "text/plain")
    ("el"   . "text/plain")
    ("js"   . "text/javascript")
    ("md"   . "text/x-markdown")
    ("gz"   . "application/octet-stream")
    ("ps"   . "application/postscript")
    ("eps"  . "application/postscript")
    ("pdf"  . "application/pdf")
    ("tar"  . "application/x-tar")
    ("zip"  . "application/zip")
    ("mp3"  . "audio/mpeg")
    ("wav"  . "audio/x-wav")
    ("flac" . "audio/flac")
    ("spx"  . "audio/ogg")
    ("oga"  . "audio/ogg")
    ("ogg"  . "audio/ogg")
    ("ogv"  . "video/ogg")
    ("mp4"  . "video/mp4")
    ("mkv"  . "video/x-matroska")
    ("webm" . "video/webm"))
  "MIME types for headers")

(defvar httpd-indexes
  '("index.html"
    "index.htm")
  "File served by default when accessing a directory.")

(defvar httpd-status-codes
  '((200 . "OK")
    (301 . "Moved Permanently")
    (302 . "Found")
    (303 . "See Other")
    (304 . "Not Modified")
    (307 . "Temporary Redirect")
    (403 . "Forbidden")
    (404 . "Not Found")
    (500 . "Internal Server Error"))
  "HTTP status codes")

(defvar httpd-html
  '((403 . "<!DOCTYPE html>
<html><head>
<title>403 Forbidden</title>
</head><body>
<h1>Forbidden</h1>
<p>The requested URL is forbidden.</p>
<pre>%s</pre>
</body></html>")
    (404 . "<!DOCTYPE html>
<html><head>
<title>404 Not Found</title>
</head><body>
<h1>Not Found</h1>
<p>The requested URL was not found on this server.</p>
<pre>%s</pre>
</body></html>")
    (500 . "<!DOCTYPE html>
<html><head>
<title>500 Internal Error</title>
</head><body>
<h1>500 Internal Error</h1>
<p>Internal error when handling this request.</p>
<pre>%s</pre>
</body></html>"))
  "HTML for various errors.")

;; User interface

;;;###autoload
(defun httpd-start ()
  "Start the emacs web server. If the server is already running,
this will restart the server. There is only one server instance
per Emacs instance."
  (interactive)
  (httpd-stop)
  (httpd-log `(start ,(current-time-string)))
  (make-network-process
   :name     "httpd"
   :service  httpd-port
   :server   t
   :family   'ipv4
   :filter   'httpd--filter
   :filter-multibyte nil
   :coding   'utf-8-unix  ; *should* be ISO-8859-1 but that doesn't work
   :log      'httpd--log)
  (run-hooks 'httpd-start-hook))

;;;###autoload
(defun httpd-stop ()
  "Stop the emacs web server if it is currently running,
otherwise do nothing."
  (interactive)
  (when (process-status "httpd")
    (delete-process "httpd")
    (httpd-log `(stop ,(current-time-string)))
    (run-hooks 'httpd-stop-hook)))

;; Utility

(defun httpd-date-string (&optional date)
  "Return an HTTP date string (RFC 1123)."
  (let* ((zone (car (current-time-zone)))
         (now (seconds-to-time (- (float-time date) zone))))
    (format-time-string "%a, %e %b %Y %T GMT" now)))

(defun httpd-etag (file)
  "Compute the ETag for the given file."
  (concat "\"" (substring (sha1 (prin1-to-string (file-attributes file))) -16)
          "\""))

;; Networking code

(defun httpd--filter (proc string)
  "Runs each time client makes a request."
  (setq string (concat (process-get proc :previous-string) string))
  (let* ((request (httpd-parse string))
         (content-length (cadr (assoc "Content-Length" request)))
         (uri (cadar request))
         (content (cadr (assoc "Content" request)))
         (parsed-uri (httpd-parse-uri (concat uri)))
         (uri-path (nth 0 parsed-uri))
         (uri-query (append (nth 1 parsed-uri) (httpd-parse-args content)))
         (servlet (httpd-get-servlet uri-path)))
    (if (and content-length
             (< (length content) (string-to-number content-length)))
        (process-put proc :previous-string string)
      (process-put proc :previous-string nil)
      (httpd-log `(request (date ,(httpd-date-string))
                           (address ,(car (process-contact proc)))
                           (get ,uri-path)
                           ,(cons 'headers request)))
      (if (null servlet)
          (httpd--error-safe proc 404)
        (condition-case error-case
            (funcall servlet proc uri-path uri-query request)
          (error (httpd--error-safe proc 500 error-case)))))))

(defun httpd--log (server proc message)
  "Runs each time a new client connects."
  (httpd-log (list 'connection (car (process-contact proc)))))

;; Logging

(defun httpd-log (item)
  "Pretty print a lisp object to the log."
  (with-current-buffer (get-buffer-create "*httpd*")
    (setq buffer-read-only nil)
    (let ((follow (= (point) (point-max))))
      (save-excursion
        (goto-char (point-max))
        (pp item (current-buffer)))
      (if follow (goto-char (point-max))))
    (setq buffer-read-only t)
    (set-buffer-modified-p nil)))

;; Servlets

(defmacro with-httpd-buffer (proc mime &rest body)
  "Create a temporary buffer and, after the body, automatically
serve it to an HTTP client with HTTP header indicating the
specified MIME type."
  (declare (indent defun))
  (let ((proc-sym (make-symbol "--proc--")))
    `(let ((,proc-sym ,proc))
       (with-temp-buffer
         ,@body
         (httpd-send-header ,proc-sym ,mime 200)
         (httpd-send-buffer ,proc-sym (current-buffer))))))

(defmacro defservlet (name mime path-query-request &rest body)
  "Defines a simple httpd servelet. The servlet runs in a
temporary buffer which is automatically served to the client
along with a header.

A servlet that serves the contents of *scratch*,

    (defservlet scratch text/plain ()
      (insert-buffer-substring (get-buffer-create \"*scratch*\")))

A servlet that says hello,

    (defservlet hello-world text/plain (path)
      (insert \"hello, \" (file-name-nondirectory path))))"
  (declare (indent defun))
  (let ((proc-sym (make-symbol "proc"))
        (fname (intern (concat "httpd/" (symbol-name name)))))
    `(defun ,fname (,proc-sym ,@path-query-request &rest ,(gensym))
       (with-httpd-buffer ,proc-sym ,(symbol-name mime)
         ,@body))))

;; Request parsing

(defun httpd-parse (string)
  "Parse client http header into alist."
  (let* ((lines (split-string string "[\n\r]+"))
         (req (list (split-string (car lines))))
         (post (cadr (split-string string "\r\n\r\n"))))
    (dolist (line (butlast (cdr lines)))
      (push (list (car (split-string line ": "))
                  (mapconcat 'identity
                             (cdr (split-string line ": ")) ": ")) req))
    (push (list "Content" post) req)
    (reverse req)))

(defun httpd-unhex (str)
  "Fully decode the URL encoding in a string (including +'s)."
  (url-unhex-string (replace-regexp-in-string (regexp-quote "+") " " str) t))

(defun httpd-parse-args (argstr)
  "Parse a string containing URL encoded arguments."
  (unless (zerop (length argstr))
    (mapcar (lambda (str)
              (mapcar 'httpd-unhex (split-string str "=")))
            (split-string argstr "&"))))

(defun httpd-parse-uri (uri)
  "Split a URI into it's components. In the return, the first
element is the script path, the second is an alist of
variable/value pairs, and the third is the fragment."
  (let ((p1 (string-match (regexp-quote "?") uri))
        (p2 (string-match (regexp-quote "#") uri))
        retval)
    (push (if p2 (httpd-unhex (substring uri (1+ p2)))) retval)
    (push (if p1 (httpd-parse-args (substring uri (1+ p1) p2))) retval)
    (push (httpd-unhex (substring uri 0 (or p1 p2))) retval)))

;; Path handling

(defun httpd-status (path)
  "Determine status code for the path."
  (cond
   ((not (file-exists-p path))   404)
   ((not (file-readable-p path)) 403)
   ((and (file-directory-p path) (not httpd-listings)) 403)
   (200)))

(defun httpd-clean-path (path)
  "Clean dangerous .. from the path and remove the leading /."
  (mapconcat 'identity
             (delete "" (delete ".." (split-string path "/"))) "/"))

(defun httpd-gen-path (path)
  "Translate GET to secure path in httpd-root."
  (let ((clean (expand-file-name (httpd-clean-path path) httpd-root)))
    (if (file-directory-p clean)
        (let* ((dir (file-name-as-directory clean))
               (indexes (mapcar* (apply-partially 'concat dir) httpd-indexes))
               (existing (remove-if-not 'file-exists-p indexes)))
          (or (car existing) dir))
      clean)))

(defun httpd-get-servlet (uri-path)
  "Determine the servlet to be executed for URI-PATH."
  (if (not httpd-servlets)
      'httpd/
    (flet ((cat (x) (concat "httpd/" (mapconcat 'identity (reverse x) "/"))))
      (let ((parts (cdr (split-string (directory-file-name uri-path) "/"))))
        (or
         (find-if 'fboundp (mapcar 'intern-soft (maplist 'cat (reverse parts))))
         'httpd/)))))

(defun httpd/ (proc uri-path query request)
  "Default root servlet which serves files when httpd-serve-files is T."
  (if httpd-serve-files
      (let* ((path (httpd-gen-path uri-path))
             (status (httpd-status path)))
        (cond
         ((not (= status 200))    (httpd-error          proc status))
         ((file-directory-p path) (httpd-send-directory proc path uri-path))
         (t                       (httpd-send-file      proc path request))))
    (httpd-error proc 403)))

(defun httpd-get-mime (ext)
  "Fetch MIME type given the file extention."
  (or (and ext (cdr (assoc (downcase ext) httpd-mime-types)))
      "application/octet-stream"))

;; Data sending functions

(defun httpd-send-header (proc mime status &rest extra-headers)
  "Send an HTTP header with given MIME type."
  (let ((status-str (cdr (assq status httpd-status-codes)))
        (headers (append (list (cons "Server" httpd-server-name)
                               (cons "Date" (httpd-date-string))
                               (cons "Connection" "keep-alive")
                               (cons "Content-Type" mime))
                         extra-headers)))
    (with-temp-buffer
      (insert (format "HTTP/1.1 %d %s\r\n" status status-str))
      (dolist (header headers)
        (insert (format "%s: %s\r\n" (car header) (cdr header))))
      (process-send-region proc (point-min) (point-max)))))

(defun httpd-redirect (proc path &optional code)
  "Redirect the client to a new location (default 301)."
  (httpd-log (list 'redirect path))
  (httpd-send-header proc "text/plain" (or code 301) (cons "Location" path))
  (with-temp-buffer
    (httpd-send-buffer proc (current-buffer))))

(defun httpd-send-file (proc path &optional req)
  "Serve file to the given client."
  (let ((req-etag (cadr (assoc "If-None-Match" req)))
        (etag (httpd-etag path))
        (mtime (httpd-date-string (nth 4 (file-attributes path)))))
    (if (equal req-etag etag)
        (with-temp-buffer
          (httpd-log `(file ,path not-modified))
          (httpd-send-header proc "text/plain" 304)
          (httpd-send-buffer proc (current-buffer)))
      (httpd-log `(file ,path))
      (httpd-send-header proc (httpd-get-mime (file-name-extension path)) 200
                         (cons "Last-Modified" mtime)
                         (cons "ETag" etag))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents path)
        (httpd-send-buffer proc (current-buffer))))))

(defun httpd-send-directory (proc path uri-path)
  "Serve a file listing to the client."
  (let ((title (concat "Directory listing for "
                       (url-insert-entities-in-string uri-path))))
    (if (equal "/" (substring uri-path -1))
        (with-temp-buffer
          (httpd-log `(directory ,path))
          (httpd-send-header proc "text/html" 200)
          (set-buffer-multibyte nil)
          (insert "<!DOCTYPE html>\n")
          (insert "<html>\n<head><title>" title "</title></head>\n")
          (insert "<body>\n<h2>" title "</h2>\n<hr/>\n<ul>")
          (dolist (file (directory-files path))
            (unless (eq ?. (aref file 0))
              (let* ((full (expand-file-name file path))
                     (tail (if (file-directory-p full) "/" ""))
                     (f (url-insert-entities-in-string file))
                     (l (url-hexify-string file)))
                (insert (format "<li><a href=\"%s%s\">%s%s</a></li>\n"
                                l tail f tail)))))
          (insert "</ul>\n<hr/>\n</body>\n</html>")
          (httpd-send-buffer proc (current-buffer)))
      (httpd-redirect proc (concat uri-path "/")))))

(defun httpd--buffer-size (buffer)
  "Get the buffer size in bytes."
  (let ((orig enable-multibyte-characters)
        (size 0))
    (with-current-buffer buffer
      (set-buffer-multibyte nil)
      (setq size (buffer-size))
      (if orig (set-buffer-multibyte orig)))
    size))

(defun httpd-send-buffer (proc buffer)
  "Send BUFFER to client."
  (let ((h (format "Content-Length: %d\r\n\r\n" (httpd--buffer-size buffer))))
    (process-send-string proc h))
  (with-current-buffer buffer
    (process-send-region proc (point-min) (point-max))))

(defun httpd-error (proc status &optional info)
  "Send an error page appropriate for STATUS to the client,
optionally inserting object INFO into page."
  (httpd-log `(error ,status ,info))
  (httpd-send-header proc "text/html" status)
  (with-temp-buffer
    (let ((html (cdr (assq status httpd-html)))
          (erro (url-insert-entities-in-string (format "error: %s"  info))))
      (insert (format html (if info erro ""))))
    (httpd-send-buffer proc (current-buffer))))

(defun httpd--error-safe (&rest args)
  "Call httpd-error and report failures to *httpd*."
  (condition-case error-case
      (apply #'httpd-error args)
    (error (httpd-log `(hard-error ,error-case)))))

(provide 'simple-httpd)

;;; simple-httpd.el ends here
