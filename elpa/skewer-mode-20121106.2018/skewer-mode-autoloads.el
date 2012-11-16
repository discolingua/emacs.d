;;; skewer-mode-autoloads.el --- automatically extracted autoloads
;;
;;; Code:


;;;### (autoloads (run-skewer skewer-mode) "skewer-mode" "skewer-mode.el"
;;;;;;  (20633 57275))
;;; Generated autoloads from skewer-mode.el

(autoload 'skewer-mode "skewer-mode" "\
Minor mode for interacting with a browser.

\(fn &optional ARG)" t nil)

(add-hook 'js2-mode-hook 'skewer-mode)

(autoload 'run-skewer "skewer-mode" "\
Attach a browser to Emacs for a skewer JavaScript REPL. Uses
`browse-url' to launch a browser.

\(fn)" t nil)

;;;***

;;;### (autoloads (skewer-proxy-enable) "skewer-proxy" "skewer-proxy.el"
;;;;;;  (20633 57275))
;;; Generated autoloads from skewer-proxy.el

(autoload 'skewer-proxy-enable "skewer-proxy" "\
Enable the skewer proxy, overwriting the httpd/ servlet.

\(fn)" t nil)

;;;***

;;;### (autoloads (skewer-repl) "skewer-repl" "skewer-repl.el" (20633
;;;;;;  57275))
;;; Generated autoloads from skewer-repl.el

(autoload 'skewer-repl "skewer-repl" "\
Start a JavaScript REPL to be evaluated in the visiting browser.

\(fn)" t nil)

;;;***

;;;### (autoloads nil nil ("skewer-mode-pkg.el") (20633 57275 970222))

;;;***

(provide 'skewer-mode-autoloads)
;; Local Variables:
;; version-control: never
;; no-byte-compile: t
;; no-update-autoloads: t
;; coding: utf-8
;; End:
;;; skewer-mode-autoloads.el ends here
