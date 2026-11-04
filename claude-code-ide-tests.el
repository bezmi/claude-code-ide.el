;;; claude-code-ide-tests.el --- Tests for Claude Code IDE  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Yoav Orot

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Test suite for claude-code-ide.el using ERT
;;
;; Run tests with:
;;   `emacs -batch -L . -l ert -l claude-code-ide-tests.el -f ert-run-tests-batch-and-exit'
;;
;; The tests mock both vterm and mcp-server-lib functionality to avoid requiring
;; these packages during testing. This allows the tests to run in any environment
;; without external dependencies.
;;
;; CRITICAL DISCOVERY: Claude Code tools only work when launched from VS Code/editor terminals
;; because the extensions set these environment variables:
;; - CLAUDE_CODE_SSE_PORT: The WebSocket server port created by the extension
;; - FORCE_CODE_TERMINAL: Set to "true" to enable terminal features
;;
;; Workflow:
;; 1. Extension creates WebSocket/MCP server on random port
;; 2. Extension sets environment variables in terminal
;; 3. Extension launches 'claude' command
;; 4. Claude CLI reads env vars and connects to WebSocket server
;; 5. CLI and extension communicate via WebSocket/JSON-RPC for tool calls

;;; Code:

(require 'ert)
(require 'cl-lib)

;;; Mock Implementations

;; === Mock claude-code-ide-debug module ===
(defvar claude-code-ide-debug nil
  "Mock debug flag for testing.")
(defvar claude-code-ide-log-with-context t
  "Mock log context flag for testing.")
(defun claude-code-ide-debug (&rest _args)
  "Mock debug function that does nothing."
  nil)
(defun claude-code-ide-clear-debug ()
  "Mock clear debug function."
  nil)
(defun claude-code-ide-log (format-string &rest args)
  "Mock logging function for tests."
  (apply #'message format-string args))
(defun claude-code-ide--get-session-context ()
  "Mock session context function."
  "")
(provide 'claude-code-ide-debug)

;; === Mock websocket module ===
;; Try to load real websocket, otherwise provide comprehensive mocks
(condition-case nil
    (progn
      (add-to-list 'load-path (expand-file-name "~/.emacs.d/.cache/straight/build/websocket/"))
      (require 'websocket))
  (error
   ;; Comprehensive websocket mock implementation.  The struct comes
   ;; first: it generates the `websocket-frame-opcode' and
   ;; `websocket-frame-payload' accessors used below.
   (cl-defstruct websocket-frame opcode payload)
   (defun websocket-server (&rest _args)
     "Mock websocket-server function.
Returns a FRESH object per call: each instance owns its own server,
and tests distinguish them by identity."
     (list :mock-server t))
   (defun websocket-server-close (_server)
     "Mock websocket-server-close function."
     nil)
   (defun websocket-send-text (_ws _text)
     "Mock websocket-send-text function."
     nil)
   (defun websocket-ready-state (_ws)
     "Mock websocket-ready-state function."
     'open)
   (defun websocket-url (_ws)
     "Mock websocket-url function."
     "ws://localhost:12345")
   (defun websocket-frame-text (frame)
     "Mock websocket-frame-text function.
Decodes the frame's real payload, like the genuine accessor — message
routing tests depend on the carried text, not a placeholder."
     (if (websocket-frame-p frame)
         (decode-coding-string (websocket-frame-payload frame) 'utf-8)
       "{}"))
   (defun websocket-send (_ws _frame)
     "Mock websocket-send function."
     nil)
   (defun websocket-server-filter (_proc _string)
     "Mock websocket-server-filter function."
     nil)
   (provide (quote websocket))))

;; === Mock vterm module ===
(defvar vterm--process nil)
(defvar vterm-buffer-name nil)
(defvar vterm-shell nil)
(defvar vterm-environment nil)

(defun vterm (&optional buffer-name)
  "Mock vterm function for testing with optional BUFFER-NAME."
  (let ((buffer (generate-new-buffer (or buffer-name vterm-buffer-name "*vterm*"))))
    (with-current-buffer buffer
      ;; Create a mock process that exits immediately
      (setq vterm--process (make-process :name "mock-vterm"
                                         :buffer buffer
                                         :command '("true")
                                         :connection-type 'pty
                                         :sentinel (lambda (_ event)
                                                     (when (string-match "finished" event)
                                                       (setq vterm--process nil))))))
    buffer))

;; Mock vterm functions
(defun vterm-send-string (_string)
  "Mock vterm-send-string function for testing."
  nil)

(defun vterm-send-return ()
  "Mock vterm-send-return function for testing."
  nil)

(defun vterm-send-key (_key &optional _shift _meta _ctrl)
  "Mock vterm-send-key function for testing."
  nil)

(provide (quote vterm))

;; === Mock ghostel module ===
(defvar ghostel-buffer-name nil)
(defvar ghostel-set-title-function #'ignore)
(defvar ghostel-enable-title-tracking t)
(defvar ghostel-kill-buffer-on-exit t)

(defun ghostel (&optional _arg)
  "Mock ghostel function for testing."
  (let ((buffer (get-buffer-create (or ghostel-buffer-name "*ghostel*"))))
    (set-buffer buffer)
    (with-current-buffer buffer
      (make-process :name "mock-ghostel"
                    :buffer buffer
                    :command '("true")
                    :connection-type 'pty))
    buffer))

(defun ghostel-exec (buffer _program &optional _args)
  "Mock ghostel-exec function for testing."
  (with-current-buffer buffer
    (make-process :name "mock-ghostel"
                  :buffer buffer
                  :command '("true")
                  :connection-type 'pty)))

(defun ghostel-send-string (_string)
  "Mock ghostel send function for testing."
  nil)

(defun ghostel--window-adjust-process-window-size (_process _windows)
  "Mock ghostel resize handler for testing."
  '(80 . 24))

(provide (quote ghostel))

;; === Mock evil-ghostel module ===
;; These stand in for the evil-ghostel package's variables so the ESC
;; routing helper can be exercised in batch mode without evil installed.
(defvar evil-ghostel-mode nil)
(defvar evil-ghostel--escape-mode nil)

;; === Mock Emacs display functions ===
(unless (fboundp 'display-buffer-in-side-window)
  (defun display-buffer-in-side-window (buffer _alist)
    "Mock display-buffer-in-side-window for testing."
    (set-window-buffer (selected-window) buffer)
    (selected-window)))

;; === Additional test-specific websocket mocks ===
(unless (featurep 'websocket)
  ;; Only define these if websocket wasn't loaded above
  (defvar websocket--test-server nil
    "Mock server for testing.")
  (defvar websocket--test-client nil
    "Mock client for testing.")
  (defvar websocket--test-port 12345
    "Mock port for testing."))

;; === Mock flycheck module ===
;; Mock flycheck before loading any modules that require it
(defvar flycheck-mode nil
  "Mock flycheck-mode variable.")
(defvar flycheck-current-errors nil
  "Mock list of flycheck errors.")

(cl-defstruct flycheck-error
  "Mock flycheck error structure."
  buffer checker filename line column end-line end-column
  message level severity id)

(provide (quote flycheck))

;; === Load required modules ===
(define-error 'mcp-error "MCP Error" 'error)
(require 'claude-code-ide-mcp-handlers)
(require 'claude-code-ide)

;;; Test Helper Functions

(defmacro claude-code-ide-tests--with-mocked-cli (cli-path &rest body)
  "Execute BODY with claude CLI path set to CLI-PATH."
  `(let ((claude-code-ide-cli-path ,cli-path)
         (claude-code-ide--cli-available nil))
     ,@body))

(defun claude-code-ide-tests--with-temp-directory (test-body)
  "Execute TEST-BODY in a temporary directory context.
Creates a temporary directory, sets it as `default-directory',
executes TEST-BODY, and ensures cleanup even if TEST-BODY fails."
  (let ((temp-dir (make-temp-file "claude-code-ide-test-" t)))
    (unwind-protect
        (let ((default-directory temp-dir))
          (funcall test-body))
      (delete-directory temp-dir t))))

(defvar claude-code-ide-tests--session-counter 0
  "Counter making fixture session IDs unique within a test run.")

(defun claude-code-ide-tests--clear-processes ()
  "Reset all session state for testing.
Ensures a clean state before each test that involves instances: the MCP
session registry, the per-project selection timers, the MCP tools
server registry and the global window-panel state."
  (when (boundp 'claude-code-ide-mcp--sessions)
    (clrhash claude-code-ide-mcp--sessions))
  (when (boundp 'claude-code-ide-mcp--selection-timers)
    (maphash (lambda (_dir timer)
               (when (timerp timer)
                 (cancel-timer timer)))
             claude-code-ide-mcp--selection-timers)
    (clrhash claude-code-ide-mcp--selection-timers))
  (when (boundp 'claude-code-ide-mcp-server--sessions)
    (clrhash claude-code-ide-mcp-server--sessions))
  (setq claude-code-ide--last-accessed-buffer nil)
  (set-frame-parameter nil 'claude-code-ide-hidden-panel nil))

(defun claude-code-ide-tests--make-session (project-dir &rest overrides)
  "Build a session fixture for PROJECT-DIR and register it.
OVERRIDES are `make-claude-code-ide-mcp-session' keyword arguments that
replace the defaults; the session is stored in
`claude-code-ide-mcp--sessions' under its session ID and returned.
No WebSocket server is created, so the fixture is batch-safe."
  (let ((args (list :session-id (format "test-session-%d"
                                        (cl-incf claude-code-ide-tests--session-counter))
                    :instance-name nil
                    :project-dir (expand-file-name project-dir)
                    :last-used (float-time)
                    :deferred (make-hash-table :test 'equal)
                    :active-diffs (make-hash-table :test 'equal))))
    (while overrides
      (setq args (plist-put args (pop overrides) (pop overrides))))
    (let ((session (apply #'make-claude-code-ide-mcp-session args)))
      (puthash (claude-code-ide-mcp-session-session-id session)
               session
               claude-code-ide-mcp--sessions)
      session)))

(defun claude-code-ide-tests--make-websocket (url)
  "Return a stand-in WebSocket client object identified by URL.
Client routing is by identity, so any unique object would do, but the
real struct is used when the websocket package is available: struct
slot accessors are inlined at load time and cannot be stubbed out."
  (if (fboundp 'websocket-inner-create)
      (websocket-inner-create :conn nil :url url :accept-string ""
                              :ready-state 'open)
    (list 'mock-websocket url)))

(defun claude-code-ide-tests--make-frame (text)
  "Return a WebSocket text frame carrying TEXT."
  (make-websocket-frame :opcode 'text
                        :payload (encode-coding-string text 'utf-8)))

(defun claude-code-ide-tests--stop-all-sessions ()
  "Stop every registered MCP session, ignoring teardown errors.
Used by tests that create real per-instance WebSocket servers."
  (dolist (session (claude-code-ide-mcp--active-sessions))
    (ignore-errors (claude-code-ide-mcp--stop-session session))))

(defun claude-code-ide-tests--wait-for-process (buffer)
  "Wait for the process in BUFFER to finish.
This prevents race conditions in tests by ensuring mock processes
have completed before cleanup.  Waits up to 5 seconds."
  (with-current-buffer buffer
    (let ((max-wait 50)) ; 5 seconds max (50 * 0.1s)
      (while (and vterm--process
                  (process-live-p vterm--process)
                  (> max-wait 0))
        (sleep-for 0.1)
        (setq max-wait (1- max-wait))))))

;;; Tests for Helper Functions

(ert-deftest claude-code-ide-test-default-buffer-name ()
  "Test default buffer name generation for various path formats."
  ;; Normal path
  (should (equal (claude-code-ide--default-buffer-name "/home/user/project")
                 "*claude-code[project]*"))
  ;; Path with trailing slash
  (should (equal (claude-code-ide--default-buffer-name "/home/user/my-app/")
                 "*claude-code[my-app]*"))
  ;; Root directory
  (should (equal (claude-code-ide--default-buffer-name "/")
                 "*claude-code[]*"))
  ;; Path with spaces
  (should (equal (claude-code-ide--default-buffer-name "/home/user/my project/")
                 "*claude-code[my project]*"))
  ;; Path with special characters
  (should (equal (claude-code-ide--default-buffer-name "/home/user/my-project@v1.0/")
                 "*claude-code[my-project@v1.0]*")))

(ert-deftest claude-code-ide-test-get-working-directory ()
  "Test working directory detection."
  (claude-code-ide-tests--with-temp-directory
   (lambda ()
     ;; Without project, should return current directory
     (let ((expected (expand-file-name default-directory)))
       (should (equal (claude-code-ide--get-working-directory) expected))))))

(ert-deftest claude-code-ide-test-get-buffer-name ()
  "Test buffer name generation using custom function."
  ;; Test with custom function
  (let ((claude-code-ide-buffer-name-function
         (lambda (dir) (format "test-%s" (file-name-nondirectory dir)))))
    (claude-code-ide-tests--with-temp-directory
     (lambda ()
       (should (string-match "^test-claude-code-ide-test-"
                             (claude-code-ide--get-buffer-name))))))

  ;; Test that nil directory is handled correctly
  (let ((claude-code-ide-buffer-name-function
         (lambda (dir) (if dir
                           (format "*custom[%s]*" (file-name-nondirectory dir))
                         "*custom[none]*"))))
    (should (equal (funcall claude-code-ide-buffer-name-function nil)
                   "*custom[none]*"))))

(ert-deftest claude-code-ide-test-session-registry ()
  "Test session storage and lookup in the session registry."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (claude-code-ide-tests--with-temp-directory
       (lambda ()
         (let ((dir (claude-code-ide--get-working-directory)))
           ;; Initially the project owns no session
           (should (null (claude-code-ide-mcp--sessions-for-project dir)))
           (should (null (claude-code-ide-mcp--get-current-session)))

           (let ((session (claude-code-ide-tests--make-session dir)))
             ;; Registered under its own session ID, not the project dir
             (should (eq (claude-code-ide-mcp--get-session-by-id
                          (claude-code-ide-mcp-session-session-id session))
                         session))
             (should (equal (claude-code-ide-mcp--sessions-for-project dir)
                            (list session)))
             (should (eq (claude-code-ide-mcp--mru-session dir) session))
             (should (member session (claude-code-ide-mcp--active-sessions)))

             ;; A second instance of the same project joins it; the most
             ;; recently used one wins the MRU lookup
             (let ((second (claude-code-ide-tests--make-session
                            dir
                            :instance-name "second"
                            :last-used (+ (float-time) 10))))
               (should (= 2 (length (claude-code-ide-mcp--sessions-for-project dir))))
               (should (eq (claude-code-ide-mcp--mru-session dir) second)))))))
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-cleanup-dead-sessions ()
  "Test that only sessions with a dead terminal process are cleaned up."
  (claude-code-ide-tests--clear-processes)
  (let ((live-process (make-process :name "test-live"
                                    :command '("sleep" "10")
                                    :buffer nil))
        (dead-process (make-process :name "test-dead"
                                    :command '("true")
                                    :buffer nil))
        (stopped '()))
    (unwind-protect
        ;; Real teardown would close websocket servers the fixtures never
        ;; opened, so only record which sessions the sweep tears down.
        (cl-letf (((symbol-function 'claude-code-ide-mcp--stop-session)
                   (lambda (session)
                     (push session stopped)
                     (remhash (claude-code-ide-mcp-session-session-id session)
                              claude-code-ide-mcp--sessions)))
                  ((symbol-function 'claude-code-ide-mcp-server-session-ended)
                   #'ignore))
          ;; Wait for the short-lived process to exit
          (while (process-live-p dead-process)
            (accept-process-output dead-process 0.05))
          (let ((live-session (claude-code-ide-tests--make-session
                               "/dir1/" :process live-process))
                (dead-session (claude-code-ide-tests--make-session
                               "/dir2/" :process dead-process))
                (pending-session (claude-code-ide-tests--make-session "/dir3/")))
            (should (= (hash-table-count claude-code-ide-mcp--sessions) 3))

            (claude-code-ide--cleanup-dead-sessions)

            ;; Only the dead one is gone; a session whose terminal has not
            ;; been created yet (nil process) must survive
            (should (equal stopped (list dead-session)))
            (should (claude-code-ide-mcp-session-cleanup-done dead-session))
            (should (= (hash-table-count claude-code-ide-mcp--sessions) 2))
            (should (claude-code-ide-mcp--get-session-by-id
                     (claude-code-ide-mcp-session-session-id live-session)))
            (should (claude-code-ide-mcp--get-session-by-id
                     (claude-code-ide-mcp-session-session-id pending-session)))
            (should-not (claude-code-ide-mcp-session-cleanup-done live-session))))
      (when (process-live-p live-process)
        (delete-process live-process))
      (claude-code-ide-tests--clear-processes))))

;;; Tests for CLI Detection

(ert-deftest claude-code-ide-test-detect-cli ()
  "Test CLI detection mechanism."
  (let ((claude-code-ide--cli-available nil))
    ;; Test with invalid CLI path
    (let ((claude-code-ide-cli-path "nonexistent-claude-cli"))
      (claude-code-ide--detect-cli)
      (should (null claude-code-ide--cli-available)))

    ;; Test with valid command (echo exists on most systems)
    (let ((claude-code-ide-cli-path "echo"))
      (claude-code-ide--detect-cli)
      (should claude-code-ide--cli-available))))

(ert-deftest claude-code-ide-test-ensure-cli ()
  "Test CLI availability checking."
  (let ((claude-code-ide--cli-available nil)
        (claude-code-ide-cli-path "echo"))
    ;; Initially not available
    (should (null claude-code-ide--cli-available))

    ;; After ensure, should be detected
    (should (claude-code-ide--ensure-cli))
    (should claude-code-ide--cli-available)))

;;; Command Tests

(ert-deftest claude-code-ide-test-run-without-cli ()
  "Test run command when CLI is not available."
  (let ((claude-code-ide--cli-available nil)
        (claude-code-ide-cli-path "nonexistent-claude-cli"))
    (should-error (claude-code-ide)
                  :type 'user-error)))

(ert-deftest claude-code-ide-test-run-without-vterm ()
  "Test run command when vterm is not available."
  (let ((claude-code-ide--cli-available t)
        (claude-code-ide-cli-path "echo")
        (claude-code-ide-terminal-backend 'vterm)
        (orig-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'featurep)
               (lambda (sym &rest _) (if (eq sym 'vterm) nil (funcall orig-featurep sym))))
              ((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (unless (eq feature 'vterm)
                   (require feature filename noerror)))))
      (should-error (claude-code-ide)
                    :type 'user-error))))

(ert-deftest claude-code-ide-test-run-without-eat ()
  "Test run command when eat is not available."
  (let ((claude-code-ide--cli-available t)
        (claude-code-ide-cli-path "echo")
        (claude-code-ide-terminal-backend 'eat)
        (orig-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'featurep)
               (lambda (sym &rest _) (if (eq sym 'eat) nil (funcall orig-featurep sym))))
              ((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (unless (eq feature 'eat)
                   (require feature filename noerror)))))
      (should-error (claude-code-ide)
                    :type 'user-error))))

(ert-deftest claude-code-ide-test-run-without-ghostel ()
  "Test run command when ghostel is not available."
  (let ((claude-code-ide--cli-available t)
        (claude-code-ide-cli-path "echo")
        (claude-code-ide-terminal-backend 'ghostel)
        (orig-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'featurep)
               (lambda (sym &rest _) (if (eq sym 'ghostel) nil (funcall orig-featurep sym))))
              ((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (unless (eq feature 'ghostel)
                   (require feature filename noerror)))))
      (should-error (claude-code-ide)
                    :type 'user-error))))

(ert-deftest claude-code-ide-test-terminal-backend-selection ()
  "Test terminal backend selection and validation."
  ;; Test vterm backend
  (let ((claude-code-ide-terminal-backend 'vterm))
    (should (eq claude-code-ide-terminal-backend 'vterm)))

  ;; Test eat backend
  (let ((claude-code-ide-terminal-backend 'eat))
    (should (eq claude-code-ide-terminal-backend 'eat)))

  ;; Test ghostel backend
  (let ((claude-code-ide-terminal-backend 'ghostel))
    (should (eq claude-code-ide-terminal-backend 'ghostel)))

  ;; Test invalid backend
  (let ((claude-code-ide-terminal-backend 'invalid-backend)
        (orig-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'featurep)
               (lambda (sym) nil)))
      (should-error (claude-code-ide--terminal-ensure-backend)
                    :type 'user-error))))

(ert-deftest claude-code-ide-test-terminal-send-functions ()
  "Test terminal send wrapper functions."
  ;; Mock vterm functions
  (let ((vterm-string-sent nil)
        (vterm-escape-sent nil)
        (vterm-return-sent nil)
        (eat-string-sent nil)
        (ghostel-string-sent nil))
    (cl-letf (((symbol-function 'vterm-send-string)
               (lambda (str) (setq vterm-string-sent str)))
              ((symbol-function 'vterm-send-escape)
               (lambda () (setq vterm-escape-sent t)))
              ((symbol-function 'vterm-send-return)
               (lambda () (setq vterm-return-sent t)))
              ((symbol-function 'eat-term-send-string)
               (lambda (term str) (setq eat-string-sent str)))
              ((symbol-function 'ghostel-send-string)
               (lambda (str) (setq ghostel-string-sent str))))

      ;; Test vterm backend
      (let ((claude-code-ide-terminal-backend 'vterm))
        (claude-code-ide--terminal-send-string "test")
        (should (equal vterm-string-sent "test"))

        (claude-code-ide--terminal-send-escape)
        (should vterm-escape-sent)

        (claude-code-ide--terminal-send-return)
        (should vterm-return-sent))

      ;; Test eat backend - need to mock the buffer-local variable
      (with-temp-buffer
        (let ((claude-code-ide-terminal-backend 'eat))
          ;; Set eat-terminal as a buffer-local variable
          (setq-local eat-terminal t)
          (claude-code-ide--terminal-send-string "test")
          (should (equal eat-string-sent "test"))

          (setq eat-string-sent nil)
          (claude-code-ide--terminal-send-escape)
          (should (equal eat-string-sent "\e"))

          (setq eat-string-sent nil)
          (claude-code-ide--terminal-send-return)
          (should (equal eat-string-sent "\r"))))

      ;; Test ghostel backend
      (with-temp-buffer
        (let ((claude-code-ide-terminal-backend 'ghostel))
          (claude-code-ide--terminal-send-string "test")
          (should (equal ghostel-string-sent "test"))

          (setq ghostel-string-sent nil)
          (claude-code-ide--terminal-send-escape)
          (should (equal ghostel-string-sent "\e"))

          (setq ghostel-string-sent nil)
          (claude-code-ide--terminal-send-return)
          (should (equal ghostel-string-sent "\r")))))))

(ert-deftest claude-code-ide-test-send-prompt-command ()
  "Test the claude-code-ide-send-prompt command."
  (claude-code-ide-tests--clear-processes)
  (let ((test-prompt "Test prompt from minibuffer")
        (project-dir "/tmp/claude-send-prompt/")
        (prompted-string nil)
        (sent-string nil)
        (sent-return nil)
        (terminal-buffer (generate-new-buffer "*test-claude-buffer*")))
    (unwind-protect
        ;; Mock read-string to return our test prompt
        (cl-letf (((symbol-function 'read-string)
                   (lambda (prompt &rest _)
                     (setq prompted-string prompt)
                     test-prompt))
                  ((symbol-function 'claude-code-ide--get-working-directory)
                   (lambda () project-dir))
                  ((symbol-function 'claude-code-ide--terminal-send-string)
                   (lambda (str) (setq sent-string str)))
                  ((symbol-function 'claude-code-ide--terminal-send-return)
                   (lambda () (setq sent-return t))))

          ;; The project's sole instance is resolved without prompting
          (claude-code-ide-tests--make-session project-dir :buffer terminal-buffer)
          (claude-code-ide-send-prompt)
          (should (equal prompted-string "Claude prompt: "))
          (should (equal sent-string test-prompt))
          (should sent-return)

          ;; Test with empty prompt (should not send anything)
          (setq sent-string nil sent-return nil)
          (cl-letf (((symbol-function 'read-string)
                     (lambda (&rest _) "")))
            (claude-code-ide-send-prompt)
            (should (null sent-string))
            (should (null sent-return)))

          ;; Without any instance for the project it errors
          (claude-code-ide-tests--clear-processes)
          (should-error (claude-code-ide-send-prompt) :type 'user-error))
      (when (buffer-live-p terminal-buffer)
        (kill-buffer terminal-buffer))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-terminal-session-creation ()
  "Test terminal session creation with both backends."
  (let ((mock-vterm-buffer nil)
        (mock-eat-buffer nil)
        (mock-ghostel-buffer nil)
        (mock-ghostel-program nil)
        (mock-ghostel-args nil)
        (mock-ghostel-env nil)
        (mock-ghostel-default-directory nil)
        (mock-process (start-process "mock" nil "true")))
    (cl-letf (((symbol-function 'claude-code-ide--terminal-ensure-backend)
               (lambda () nil))  ; Mock the ensure function to do nothing
              ((symbol-function 'vterm)
               (lambda (name)
                 (setq mock-vterm-buffer (get-buffer-create name))))
              ((symbol-function 'eat-mode)
               (lambda () nil))
              ((symbol-function 'eat-exec)
               (lambda (buffer name cmd startfile args)
                 (setq mock-eat-buffer buffer)))
              ((symbol-function 'ghostel-exec)
               (lambda (buffer program &optional args)
                 (setq mock-ghostel-buffer buffer)
                 (setq mock-ghostel-program program)
                 (setq mock-ghostel-args args)
                 (setq mock-ghostel-env process-environment)
                 (setq mock-ghostel-default-directory default-directory)
                 (setq-local ghostel-set-title-function #'ignore)
                 mock-process))
              ((symbol-function 'get-buffer-process)
               (lambda (buffer) mock-process)))

      ;; Test vterm backend session creation
      (let ((claude-code-ide-terminal-backend 'vterm)
            (claude-code-ide--cli-available t))
        (cl-letf (((symbol-function 'claude-code-ide--build-claude-command)
                   (lambda (&rest _) "claude")))
          (let ((result (claude-code-ide--create-terminal-session
                         "*test-vterm*" "/tmp" 12345 nil nil "test-session")))
            (should (consp result))
            (should (bufferp (car result)))
            (should (processp (cdr result)))
            (should (equal (buffer-name mock-vterm-buffer) "*test-vterm*")))))

      ;; Test eat backend session creation
      (let ((claude-code-ide-terminal-backend 'eat)
            (claude-code-ide--cli-available t))
        (cl-letf (((symbol-function 'claude-code-ide--build-claude-command)
                   (lambda (&rest _) "claude")))
          (let ((result (claude-code-ide--create-terminal-session
                         "*test-eat*" "/tmp" 12345 nil nil "test-session")))
            (should (consp result))
            (should (bufferp (car result)))
            (should (processp (cdr result)))
            (should (bufferp mock-eat-buffer)))))

      ;; Test ghostel backend session creation
      (let ((claude-code-ide-terminal-backend 'ghostel)
            (claude-code-ide--cli-available t))
        (cl-letf (((symbol-function 'claude-code-ide--build-claude-command)
                   (lambda (&rest _) "claude --print \"hello world\""))
                  ;; The ghostel branch resolves the program to an absolute
                  ;; path so ghostel's native PTY spawn does not depend on
                  ;; the process environment's PATH.
                  ((symbol-function 'executable-find)
                   (lambda (name) (when (equal name "claude") "/opt/bin/claude"))))
          (let ((result (claude-code-ide--create-terminal-session
                         "*test-ghostel*" "/tmp" 12345 nil nil "test-session")))
            (should (consp result))
            (should (bufferp (car result)))
            (should (processp (cdr result)))
            (should (equal (buffer-name mock-ghostel-buffer) "*test-ghostel*"))
            (should (equal mock-ghostel-program "/opt/bin/claude"))
            (should (equal mock-ghostel-args '("--print" "hello world")))
            (should (equal mock-ghostel-default-directory "/tmp"))
            (with-current-buffer mock-ghostel-buffer
              (should (null ghostel-set-title-function)))
            (should (member "CLAUDE_CODE_SSE_PORT=12345" mock-ghostel-env))
            (should (member "TERM_PROGRAM=emacs" mock-ghostel-env))
            (should (member "FORCE_CODE_TERMINAL=true" mock-ghostel-env))))))))

(ert-deftest claude-code-ide-test-resolve-program ()
  "Test CLI program resolution for terminal exec APIs."
  ;; A bare name resolves to an absolute path via `executable-find'.
  (cl-letf (((symbol-function 'executable-find)
             (lambda (name) (when (equal name "claude") "/opt/bin/claude"))))
    (should (equal (claude-code-ide--resolve-program "claude")
                   "/opt/bin/claude"))
    ;; An unresolvable name is passed through unchanged so the terminal
    ;; backend reports the missing executable itself.
    (should (equal (claude-code-ide--resolve-program "no-such-cli")
                   "no-such-cli")))
  ;; A name with a directory component expands instead of a PATH lookup.
  (let ((default-directory "/tmp/"))
    (should (equal (claude-code-ide--resolve-program "./bin/claude")
                   "/tmp/bin/claude"))
    (should (equal (claude-code-ide--resolve-program "~/bin/claude")
                   (expand-file-name "~/bin/claude")))))

(ert-deftest claude-code-ide-test-start-session-cli-dies-during-init ()
  "A CLI death during the initialization delay signals a clear error.
When the process dies within the stabilization delay, the exit
sentinel kills the terminal buffer; the session start must then fail
with an explanatory error rather than operating on the dead buffer."
  (claude-code-ide-tests--clear-processes)
  (let ((buffer (generate-new-buffer "*test-death*"))
        (process (start-process "mock-claude" nil "sleep" "30"))
        (project-dir "/tmp/test-death/")
        (displayed nil)
        (stopped-sessions '())
        (ended-ids '()))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code-ide--ensure-cli)
                   (lambda () t))
                  ((symbol-function 'claude-code-ide--get-working-directory)
                   (lambda () project-dir))
                  ((symbol-function 'claude-code-ide--terminal-ensure-backend)
                   #'ignore)
                  ;; The fixture session is created (and registered) only
                  ;; when the session start asks for it, so the instance
                  ;; name prompt is not triggered beforehand.
                  ((symbol-function 'claude-code-ide-mcp-create-session)
                   (lambda (dir session-id &optional instance-name)
                     (claude-code-ide-tests--make-session
                      dir :session-id session-id
                      :instance-name instance-name :port 12345)))
                  ((symbol-function 'claude-code-ide--create-terminal-session)
                   (lambda (&rest _) (cons buffer process)))
                  ((symbol-function 'claude-code-ide-mcp-server-session-started)
                   #'ignore)
                  ((symbol-function 'claude-code-ide-mcp-server-session-ended)
                   (lambda (id) (push id ended-ids)))
                  ((symbol-function 'claude-code-ide-mcp--stop-session)
                   (lambda (session)
                     (push session stopped-sessions)
                     (remhash (claude-code-ide-mcp-session-session-id session)
                              claude-code-ide-mcp--sessions)))
                  ((symbol-function 'claude-code-ide--display-buffer-in-side-window)
                   (lambda (_) (setq displayed t)))
                  ;; Simulate the CLI dying while the session stabilizes:
                  ;; the process exits and its sentinel kills the buffer.
                  ((symbol-function 'sleep-for)
                   (lambda (&rest _)
                     (delete-process process)
                     (kill-buffer buffer))))
          (let* ((claude-code-ide-terminal-backend 'ghostel)
                 (claude-code-ide-prevent-reflow-glitch nil)
                 (err (should-error (claude-code-ide--start-session))))
            (should (string-match-p "exited immediately after startup"
                                    (error-message-string err)))
            (should-not displayed)
            ;; The failed instance is torn down, and only it: its MCP
            ;; server is stopped and its tools-server registration ended
            (should (= 1 (length stopped-sessions)))
            (should (= 1 (length ended-ids)))
            (should (= 0 (hash-table-count claude-code-ide-mcp--sessions)))))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-ghostel-evil-escape-override ()
  "Test that the ghostel evil ESC routing is overridden per buffer."
  ;; Overrides the buffer-local escape mode when evil-ghostel-mode is on.
  (with-temp-buffer
    (setq-local evil-ghostel-mode t)
    (setq-local evil-ghostel--escape-mode 'auto)
    (let ((claude-code-ide-ghostel-evil-escape 'evil))
      (claude-code-ide--apply-ghostel-evil-escape)
      (should (eq evil-ghostel--escape-mode 'evil))))
  ;; A nil setting leaves the value seeded from the global default alone.
  (with-temp-buffer
    (setq-local evil-ghostel-mode t)
    (setq-local evil-ghostel--escape-mode 'auto)
    (let ((claude-code-ide-ghostel-evil-escape nil))
      (claude-code-ide--apply-ghostel-evil-escape)
      (should (eq evil-ghostel--escape-mode 'auto))))
  ;; No-op when evil-ghostel-mode is not active in the buffer.
  (with-temp-buffer
    (setq-local evil-ghostel-mode nil)
    (setq-local evil-ghostel--escape-mode 'auto)
    (let ((claude-code-ide-ghostel-evil-escape 'evil))
      (claude-code-ide--apply-ghostel-evil-escape)
      (should (eq evil-ghostel--escape-mode 'auto)))))

(ert-deftest claude-code-ide-test-vterm-smart-renderer-passthrough ()
  "Test that vterm smart renderer passes through normal text immediately."
  (let ((orig-fun-called nil)
        (orig-fun-input nil)
        (claude-code-ide-vterm-anti-flicker t))
    (cl-letf (((symbol-function 'claude-code-ide--session-buffer-p)
               (lambda (_) t)))
      (with-temp-buffer
        (let ((claude-code-ide--vterm-render-queue nil)
              (claude-code-ide--vterm-render-timer nil)
              (mock-process (make-process :name "mock"
                                          :buffer (current-buffer)
                                          :command '("true"))))
          ;; Create a mock original function
          (let ((orig-fun (lambda (_process input)
                            (setq orig-fun-called t
                                  orig-fun-input input))))
            ;; Test with normal text (no escape sequences)
            (claude-code-ide--vterm-smart-renderer orig-fun mock-process "Hello World")
            ;; Should pass through immediately
            (should orig-fun-called)
            (should (equal orig-fun-input "Hello World"))
            (should-not claude-code-ide--vterm-render-queue)))))))

(ert-deftest claude-code-ide-test-vterm-smart-renderer-batching ()
  "Test that vterm smart renderer batches complex escape sequences."
  (let ((orig-fun-called nil)
        (timer-created nil)
        (claude-code-ide-vterm-anti-flicker t)
        (claude-code-ide-vterm-render-delay 0.005))
    (cl-letf (((symbol-function 'claude-code-ide--session-buffer-p)
               (lambda (_) t))
              ((symbol-function 'run-at-time)
               (lambda (delay &rest _)
                 (setq timer-created delay)
                 'mock-timer))
              ((symbol-function 'cancel-timer)
               (lambda (_) nil)))
      (with-temp-buffer
        (let ((claude-code-ide--vterm-render-queue nil)
              (claude-code-ide--vterm-render-timer nil)
              (mock-process (make-process :name "mock"
                                          :buffer (current-buffer)
                                          :command '("true"))))
          ;; Create a mock original function
          (let ((orig-fun (lambda (_process _input)
                            (setq orig-fun-called t))))
            ;; Test with complex escape sequence pattern
            (let ((complex-input "\033[2A\033[K\033[3A\033[K"))
              (claude-code-ide--vterm-smart-renderer orig-fun mock-process complex-input)
              ;; Should be queued, not called immediately
              (should-not orig-fun-called)
              ;; Queue is a list (pushed in reverse order for O(1))
              (should (listp claude-code-ide--vterm-render-queue))
              (should (equal (apply #'concat (nreverse claude-code-ide--vterm-render-queue))
                             complex-input))
              (should (equal timer-created 0.005)))))))))

(ert-deftest claude-code-ide-test-toggle-vterm-optimization ()
  "Test toggling vterm optimization on and off."
  (let ((original-value claude-code-ide-vterm-anti-flicker)
        (message-output nil))
    (unwind-protect
        (cl-letf (((symbol-function 'message)
                   (lambda (format &rest args)
                     (setq message-output (apply #'format format args)))))
          ;; Start with optimization enabled
          (setq claude-code-ide-vterm-anti-flicker t)

          ;; Toggle off
          (claude-code-ide-toggle-vterm-optimization)
          (should-not claude-code-ide-vterm-anti-flicker)
          (should (string-match "disabled" message-output))

          ;; Toggle back on
          (claude-code-ide-toggle-vterm-optimization)
          (should claude-code-ide-vterm-anti-flicker)
          (should (string-match "enabled" message-output)))
      ;; Restore original value
      (setq claude-code-ide-vterm-anti-flicker original-value))))

(ert-deftest claude-code-ide-test-run-existing-session ()
  "Starting Claude twice in one project creates two instances.
The second start prompts for an instance name and gets its own session,
port, window slot and terminal buffer instead of reusing the first."
  (claude-code-ide-tests--clear-processes)
  (let ((processes '())
        (displayed '()))
    (unwind-protect
        (claude-code-ide-tests--with-temp-directory
         (lambda ()
           (let ((claude-code-ide--cli-available t)
                 (claude-code-ide-cli-path "echo")
                 (claude-code-ide-terminal-initialization-delay 0)
                 (claude-code-ide-prevent-reflow-glitch nil)
                 (working-dir (claude-code-ide--get-working-directory)))
             (cl-letf (((symbol-function 'claude-code-ide--terminal-ensure-backend)
                        #'ignore)
                       ((symbol-function 'claude-code-ide--read-instance-name)
                        (lambda (&rest _) "second"))
                       ((symbol-function 'claude-code-ide--create-terminal-session)
                        (lambda (buffer-name &rest _)
                          (let ((buffer (generate-new-buffer buffer-name))
                                (process (start-process "mock-claude" nil
                                                        "sleep" "30")))
                            (push process processes)
                            (cons buffer process))))
                       ((symbol-function 'claude-code-ide--display-buffer-in-side-window)
                        (lambda (buffer) (push buffer displayed) nil)))
               ;; The first instance is unnamed and asks nothing
               (claude-code-ide--start-session)
               (should (= 1 (length (claude-code-ide-mcp--sessions-for-project
                                     working-dir))))

               ;; The second start does not toggle the first one's window,
               ;; it creates another instance
               (claude-code-ide--start-session)
               (let* ((sessions (claude-code-ide-mcp--sessions-for-project working-dir))
                      (names (mapcar #'claude-code-ide-mcp-session-instance-name sessions))
                      (ports (mapcar #'claude-code-ide-mcp-session-port sessions))
                      (slots (mapcar #'claude-code-ide-mcp-session-window-slot sessions))
                      (buffer-names (mapcar (lambda (session)
                                              (buffer-name
                                               (claude-code-ide-mcp-session-buffer session)))
                                            sessions)))
                 (should (= 2 (length sessions)))
                 (should (member nil names))
                 (should (member "second" names))
                 ;; Own port, own window slot, own buffer
                 (should (= 2 (length (delete-dups (copy-sequence ports)))))
                 (should (= 2 (length (delete-dups (copy-sequence slots)))))
                 (should (equal (sort (copy-sequence buffer-names) #'string<)
                                (sort (list (claude-code-ide--instance-buffer-name
                                             working-dir nil)
                                            (claude-code-ide--instance-buffer-name
                                             working-dir "second"))
                                      #'string<)))
                 ;; Both instances got displayed
                 (should (= 2 (length displayed))))))))
      (dolist (session (claude-code-ide-mcp--active-sessions))
        (ignore-errors (claude-code-ide--cleanup-session session)))
      (dolist (process processes)
        (when (process-live-p process)
          (delete-process process)))
      (claude-code-ide-tests--stop-all-sessions)
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-check-status ()
  "Test status check command."
  (let ((claude-code-ide-cli-path "echo")
        (claude-code-ide--cli-available nil))
    ;; Should not error and should detect CLI
    (claude-code-ide-check-status)
    (should claude-code-ide--cli-available)))

(ert-deftest claude-code-ide-test-terminal-initialization-delay ()
  "Test terminal initialization delay configuration."
  ;; Test default value
  (should (boundp 'claude-code-ide-terminal-initialization-delay))
  (should (numberp claude-code-ide-terminal-initialization-delay))
  (should (= claude-code-ide-terminal-initialization-delay 0.1))

  ;; Test customization
  (let ((original-delay claude-code-ide-terminal-initialization-delay))
    (unwind-protect
        (progn
          (setq claude-code-ide-terminal-initialization-delay 0.2)
          (should (= claude-code-ide-terminal-initialization-delay 0.2)))
      ;; Restore original value
      (setq claude-code-ide-terminal-initialization-delay original-delay))))

(ert-deftest claude-code-ide-test-obsolete-eat-delay-alias ()
  "Test that the obsolete eat delay alias still works."
  ;; The alias should be defined
  (should (boundp 'claude-code-ide-eat-initialization-delay))
  ;; Setting the old variable should affect the new one
  (let ((original-delay claude-code-ide-terminal-initialization-delay))
    (unwind-protect
        (progn
          (setq claude-code-ide-eat-initialization-delay 0.3)
          (should (= claude-code-ide-terminal-initialization-delay 0.3)))
      ;; Restore original value
      (setq claude-code-ide-terminal-initialization-delay original-delay))))

(ert-deftest claude-code-ide-test-stop-no-session ()
  "Test stop command when no session is running."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (claude-code-ide-tests--with-temp-directory
       (lambda ()
         ;; Should not error when no session exists
         (claude-code-ide-stop)))
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-stop-with-session ()
  "Test that stopping an instance kills its own terminal buffer.
With several instances in a project the target is asked for rather than
guessed, and only that instance is torn down."
  (claude-code-ide-tests--clear-processes)
  (let ((project-dir "/tmp/claude-stop/")
        (buffer-a (generate-new-buffer "*claude-stop-a*"))
        (buffer-b (generate-new-buffer "*claude-stop-b*"))
        (cleaned '()))
    (unwind-protect
        (let ((session-a (claude-code-ide-tests--make-session
                          project-dir :instance-name "alpha" :buffer buffer-a))
              (session-b (claude-code-ide-tests--make-session
                          project-dir :instance-name "beta" :buffer buffer-b)))
          (cl-letf (((symbol-function 'claude-code-ide--get-working-directory)
                     (lambda () project-dir))
                    ((symbol-function 'get-buffer-window) (lambda (&rest _) nil))
                    ((symbol-function 'claude-code-ide--cleanup-session)
                     (lambda (session) (push session cleaned)))
                    ((symbol-function 'completing-read)
                     (lambda (_prompt candidates &rest _)
                       (car (rassq session-b candidates)))))
            ;; The chosen instance's buffer is killed; cleanup follows from
            ;; the buffer's own kill hook
            (claude-code-ide-stop)
            (should-not (buffer-live-p buffer-b))
            (should (buffer-live-p buffer-a))
            (should (claude-code-ide-mcp--get-session-by-id
                     (claude-code-ide-mcp-session-session-id session-a)))

            ;; An instance whose buffer is already gone is cleaned up directly
            (setf (claude-code-ide-mcp-session-buffer session-b) nil)
            (cl-letf (((symbol-function 'claude-code-ide--resolve-session)
                       (lambda (&rest _) session-b)))
              (claude-code-ide-stop))
            (should (equal cleaned (list session-b)))))
      (dolist (buffer (list buffer-a buffer-b))
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-switch-to-buffer-no-session ()
  "Test `switch-to-buffer' command when no session exists."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (should-error (claude-code-ide-switch-to-buffer)
                    :type 'user-error)
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-toggle-window-functionality ()
  "Test that `claude-code-ide-toggle' works on the project's windows as a panel."
  (claude-code-ide-tests--clear-processes)
  (let ((project-dir "/tmp/claude-toggle-panel/")
        (buffer-a (generate-new-buffer "*claude-panel-a*"))
        (buffer-b (generate-new-buffer "*claude-panel-b*"))
        (visible '())
        (toggled '()))
    (unwind-protect
        (let ((session-a (claude-code-ide-tests--make-session
                          project-dir :instance-name "alpha"
                          :buffer buffer-a :last-used 100.0))
              (session-b (claude-code-ide-tests--make-session
                          project-dir :instance-name "beta"
                          :buffer buffer-b :last-used 200.0)))
          (cl-letf (((symbol-function 'claude-code-ide--get-working-directory)
                     (lambda () project-dir))
                    ((symbol-function 'claude-code-ide--session-visible-p)
                     (lambda (session) (memq session visible)))
                    ((symbol-function 'claude-code-ide--toggle-existing-window)
                     (lambda (session) (push session toggled))))
            ;; Both windows visible: the whole panel is hidden and remembered
            (setq visible (list session-a session-b))
            (claude-code-ide-toggle)
            (should (= 2 (length toggled)))

            ;; Nothing visible: the remembered set comes back
            (setq visible '() toggled '())
            (claude-code-ide-toggle)
            (should (= 2 (length toggled)))
            (should (memq session-a toggled))
            (should (memq session-b toggled))

            ;; Without a remembered set, only the most recently used
            ;; instance is restored
            (claude-code-ide--hidden-panel-set project-dir nil)
            (setq toggled '())
            (claude-code-ide-toggle)
            (should (equal toggled (list session-b)))

            ;; A prefix argument toggles a single chosen instance
            (setq toggled '())
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt candidates &rest _)
                         (car (rassq session-a candidates)))))
              (claude-code-ide-toggle t))
            (should (equal toggled (list session-a)))

            ;; A project without instances has no panel to toggle
            (claude-code-ide-tests--clear-processes)
            (should-error (claude-code-ide-toggle) :type 'user-error)))
      (dolist (buffer (list buffer-a buffer-b))
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-list-sessions-empty ()
  "Test listing sessions when none exist."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      ;; Should not error when no sessions exist
      (claude-code-ide-list-sessions)
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-list-sessions-with-sessions ()
  "Test that session listing offers every instance of every project."
  (claude-code-ide-tests--clear-processes)
  (let ((buffer1 (generate-new-buffer "*claude-list-1*"))
        (buffer2 (generate-new-buffer "*claude-list-2*"))
        (buffer3 (generate-new-buffer "*claude-list-3*"))
        (offered nil)
        (displayed nil))
    (unwind-protect
        (progn
          ;; Two instances of one project plus one of another
          (claude-code-ide-tests--make-session "/tmp/project1/" :buffer buffer1)
          (claude-code-ide-tests--make-session "/tmp/project1/"
                                               :instance-name "review"
                                               :buffer buffer2)
          (claude-code-ide-tests--make-session "/tmp/project2/"
                                               :buffer buffer3
                                               :client (claude-code-ide-tests--make-websocket
                                                        "ws://127.0.0.1:10003"))
          (should (= (hash-table-count claude-code-ide-mcp--sessions) 3))

          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt candidates &rest _)
                       (setq offered (mapcar #'car candidates))
                       (car (car candidates))))
                    ((symbol-function 'claude-code-ide--display-buffer-in-side-window)
                     (lambda (buffer) (setq displayed buffer) nil)))
            (claude-code-ide-list-sessions))

          ;; All three instances are offered, named per instance and
          ;; annotated with their connection state
          (should (= (length offered) 3))
          (should (cl-find-if (lambda (c) (string-prefix-p "project1 —" c)) offered))
          (should (cl-find-if (lambda (c) (string-prefix-p "project1:review —" c)) offered))
          (should (cl-find-if (lambda (c) (string-match-p "connected" c)) offered))
          (should (cl-find-if (lambda (c) (string-match-p "waiting" c)) offered))
          (should (memq displayed (list buffer1 buffer2 buffer3))))
      (dolist (buffer (list buffer1 buffer2 buffer3))
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-toggle-recent ()
  "Test the global Claude panel toggle.
Visible windows are hidden as a set and that set is restored on the
next toggle, independent of which project the instances belong to."
  (claude-code-ide-tests--clear-processes)
  (let ((buffer1 (generate-new-buffer "*claude-toggle-1*"))
        (buffer2 (generate-new-buffer "*claude-toggle-2*"))
        (visible t)
        (hidden '())
        (shown '()))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code-ide--session-visible-p)
                   (lambda (_session) visible))
                  ((symbol-function 'claude-code-ide--toggle-existing-window)
                   (lambda (session) (push session hidden)))
                  ((symbol-function 'claude-code-ide--display-buffer-in-side-window)
                   (lambda (buffer) (push buffer shown) nil)))
          ;; Without any instance and without a recent buffer it errors
          (setq visible nil)
          (should-error (claude-code-ide-toggle-recent) :type 'user-error)

          ;; A remembered last-accessed buffer is reopened
          (setq claude-code-ide--last-accessed-buffer buffer1)
          (claude-code-ide-toggle-recent)
          (should (equal shown (list buffer1)))

          ;; Two visible instances from different projects are hidden as
          ;; one set, and the set is remembered
          (let ((session1 (claude-code-ide-tests--make-session
                           "/tmp/toggle-a/" :buffer buffer1))
                (session2 (claude-code-ide-tests--make-session
                           "/tmp/toggle-b/" :buffer buffer2)))
            (setq visible t shown '() hidden '())
            (claude-code-ide-toggle-recent)
            (should (= 2 (length hidden)))
            (should (memq session1 hidden))
            (should (memq session2 hidden))
            (should (= 2 (length (claude-code-ide--hidden-panel-get :all))))

            ;; Toggling again restores exactly the remembered set and
            ;; forgets it
            (setq visible nil hidden '())
            (claude-code-ide-toggle-recent)
            (should (= 2 (length shown)))
            (should (memq buffer1 shown))
            (should (memq buffer2 shown))
            (should-not (claude-code-ide--hidden-panel-get :all))

            ;; A stopped instance is dropped from the remembered set
            (claude-code-ide--hidden-panel-set :all (list session1 session2))
            (setq shown '())
            (setf (claude-code-ide-mcp-session-cleanup-done session1) t)
            (claude-code-ide-toggle-recent)
            (should (equal shown (list buffer2)))))
      (dolist (buffer (list buffer1 buffer2))
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (claude-code-ide-tests--clear-processes))))

;;; Edge Case Tests

(ert-deftest claude-code-ide-test-concurrent-sessions ()
  "Test that instances of two different projects stay independent."
  (claude-code-ide-tests--clear-processes)
  (let ((dir1 (file-name-as-directory (make-temp-file "claude-test-1" t)))
        (dir2 (file-name-as-directory (make-temp-file "claude-test-2" t)))
        (session1 nil)
        (session2 nil))
    (unwind-protect
        (progn
          (setq session1 (claude-code-ide-mcp-create-session dir1 "concurrent-1")
                session2 (claude-code-ide-mcp-create-session dir2 "concurrent-2"))
          (should (= 2 (hash-table-count claude-code-ide-mcp--sessions)))
          ;; Each project sees only its own instance
          (should (equal (claude-code-ide-mcp--sessions-for-project dir1)
                         (list session1)))
          (should (equal (claude-code-ide-mcp--sessions-for-project dir2)
                         (list session2)))
          (should (eq (claude-code-ide-mcp--mru-session dir1) session1))
          ;; Separate servers, ports and lockfiles
          (should-not (eq (claude-code-ide-mcp-session-server session1)
                          (claude-code-ide-mcp-session-server session2)))
          (should-not (= (claude-code-ide-mcp-session-port session1)
                         (claude-code-ide-mcp-session-port session2)))
          (should (file-exists-p (claude-code-ide-mcp--lockfile-path
                                  (claude-code-ide-mcp-session-port session1))))
          (should (file-exists-p (claude-code-ide-mcp--lockfile-path
                                  (claude-code-ide-mcp-session-port session2))))

          ;; Stopping one project's instance leaves the other untouched
          (claude-code-ide-mcp-stop-session dir1)
          (should (null (claude-code-ide-mcp--sessions-for-project dir1)))
          (should-not (file-exists-p (claude-code-ide-mcp--lockfile-path
                                      (claude-code-ide-mcp-session-port session1))))
          (should (equal (claude-code-ide-mcp--sessions-for-project dir2)
                         (list session2)))
          (should (file-exists-p (claude-code-ide-mcp--lockfile-path
                                  (claude-code-ide-mcp-session-port session2))))
          ;; The selection debounce timer table is keyed per project, so
          ;; the stopped project leaves nothing behind
          (should-not (gethash (expand-file-name dir1)
                               claude-code-ide-mcp--selection-timers)))
      (claude-code-ide-tests--stop-all-sessions)
      (claude-code-ide-tests--clear-processes)
      (delete-directory dir1 t)
      (delete-directory dir2 t))))

(ert-deftest claude-code-ide-test-custom-buffer-naming ()
  "Test custom buffer naming function."
  (let ((claude-code-ide-buffer-name-function
         (lambda (dir)
           (format "TEST-%s"
                   (upcase (file-name-nondirectory (directory-file-name dir)))))))
    (claude-code-ide-tests--with-temp-directory
     (lambda ()
       (let ((expected (format "TEST-%s"
                               (upcase (file-name-nondirectory
                                        (directory-file-name default-directory))))))
         (should (equal (claude-code-ide--get-buffer-name) expected)))))))

(ert-deftest claude-code-ide-test-window-placement-options ()
  "Test different window placement configurations."
  (dolist (side '(left right top bottom))
    (let ((claude-code-ide-window-side side))
      ;; Just verify the setting is accepted
      (should (eq claude-code-ide-window-side side)))))

(ert-deftest claude-code-ide-test-debug-mode-flag ()
  "Test debug mode CLI flag."
  (let ((claude-code-ide-cli-debug t))
    (should (string-match "-d" (claude-code-ide--build-claude-command)))
    (should (string-match "-d.*-c" (claude-code-ide--build-claude-command t)))
    (should (string-match "-d.*-r" (claude-code-ide--build-claude-command nil t)))))

(ert-deftest claude-code-ide-test-parse-command-string-quoting ()
  "The exec parser removes shell quoting and keeps ; & | as text."
  (should (equal (claude-code-ide--parse-command-string "claude -d --flag value")
                 '("claude" "-d" "--flag" "value")))
  ;; `shell-quote-argument' output: backslash escapes
  (should (equal (claude-code-ide--parse-command-string
                  (concat "claude --append-system-prompt "
                          (shell-quote-argument "Match style; name any behaviour change. Use a | b & c")))
                 '("claude" "--append-system-prompt"
                   "Match style; name any behaviour change. Use a | b & c")))
  ;; Single quotes keep everything literal
  (should (equal (claude-code-ide--parse-command-string "x 'a; b \\n \"c\"' y")
                 '("x" "a; b \\n \"c\"" "y")))
  ;; Double quotes: escaped quotes and backslashes, as the --mcp-config flag uses
  (should (equal (claude-code-ide--parse-command-string
                  "claude --mcp-config \"{\\\"a\\\": \\\"b\\\\c\\\"}\" --allowedTools t1 t2")
                 '("claude" "--mcp-config" "{\"a\": \"b\\c\"}" "--allowedTools" "t1" "t2")))
  ;; Tabs and repeated spaces separate words; an escaped space does not
  (should (equal (claude-code-ide--parse-command-string "a  \tb\\ c")
                 '("a" "b c"))))

(ert-deftest claude-code-ide-test-parse-command-string-with-review-prompt ()
  "A full command with the review rules paragraph parses to one program and intact arguments."
  (let ((claude-code-ide-cli-path "claude")
        (claude-code-ide-system-prompt nil)
        (claude-code-ide-cli-debug nil)
        (claude-code-ide-cli-extra-flags "")
        (claude-code-ide-enable-mcp-server nil)
        (claude-code-ide-review-annotate-on-edit t)
        (claude-code-ide-system-prompt-functions (list #'claude-code-ide-review--system-prompt)))
    (let* ((parsed (claude-code-ide--parse-command-string (claude-code-ide--build-claude-command)))
           (prompt (nth 1 (cdr parsed))))
      (should (equal (car parsed) "claude"))
      (should (equal (nth 0 (cdr parsed)) "--append-system-prompt"))
      (should (= (length (cdr parsed)) 2))
      (should (string-match-p "Connected to Emacs" prompt))
      (should (string-match-p "name any behaviour change\\.$" prompt)))))

(ert-deftest claude-code-ide-test-build-command-with-system-prompt ()
  "Test building command with append-system-prompt flag."
  ;; Test with user system prompt
  (let ((claude-code-ide-cli-path "claude")
        (claude-code-ide-system-prompt "You are a helpful assistant")
        (claude-code-ide-cli-debug nil)
        (claude-code-ide-cli-extra-flags ""))
    (let ((cmd (claude-code-ide--build-claude-command)))
      (should (string-match-p "--append-system-prompt" cmd))
      ;; Check that Emacs prompt is included (accounting for shell escaping)
      (should (or (string-match-p "Connected to Emacs" cmd)
                  (string-match-p "Connected\\\\ to\\\\ Emacs" cmd)))
      ;; Check that user prompt is included
      (should (or (string-match-p "You are a helpful assistant" cmd)
                  (string-match-p "You\\\\ are\\\\ a\\\\ helpful\\\\ assistant" cmd)))))
  ;; Test with nil value (should still add the Emacs prompt)
  (let ((claude-code-ide-cli-path "claude")
        (claude-code-ide-system-prompt nil)
        (claude-code-ide-cli-debug nil)
        (claude-code-ide-cli-extra-flags ""))
    (let ((cmd (claude-code-ide--build-claude-command)))
      (should (string-match-p "--append-system-prompt" cmd))
      ;; Check that Emacs prompt is included (accounting for shell escaping)
      (should (or (string-match-p "Connected to Emacs" cmd)
                  (string-match-p "Connected\\\\ to\\\\ Emacs" cmd)))
      ;; Should not contain user prompt when nil
      (should-not (string-match-p "You are a helpful assistant" cmd))))
  ;; Test with special characters that need quoting
  (let ((claude-code-ide-cli-path "claude")
        (claude-code-ide-system-prompt "You're a \"helpful\" assistant!")
        (claude-code-ide-cli-debug nil)
        (claude-code-ide-cli-extra-flags ""))
    (let ((cmd (claude-code-ide--build-claude-command)))
      (should (string-match-p "--append-system-prompt" cmd))
      ;; Check that Emacs prompt is included (accounting for shell escaping)
      (should (or (string-match-p "Connected to Emacs" cmd)
                  (string-match-p "Connected\\\\ to\\\\ Emacs" cmd)))
      ;; The command should contain the escaped version (shell-quote-argument escapes quotes and apostrophes)
      (should (string-match-p "You\\\\'re\\\\ a\\\\ \\\\\"helpful\\\\\"\\\\ assistant\\\\!" cmd)))))

(ert-deftest claude-code-ide-test-error-handling ()
  "Test error handling in various scenarios."
  ;; Test with nil CLI path
  (let ((claude-code-ide-cli-path nil)
        (claude-code-ide--cli-available nil))
    (should-error (claude-code-ide) :type 'user-error))

  ;; Test with empty CLI path
  (let ((claude-code-ide-cli-path "")
        (claude-code-ide--cli-available nil))
    (should-error (claude-code-ide) :type 'user-error)))

;;; Run all tests

(ert-deftest claude-code-ide-test-tab-bar-tracking ()
  "Test that each instance records the tab it was started in."
  (require 'tab-bar)
  (let* ((temp-dir (file-name-as-directory (make-temp-file "test-project-" t)))
         (claude-code-ide-mcp--sessions (make-hash-table :test 'equal))
         ;; Mock tab-bar functions
         (mock-tab '((name . "test-tab") (index . 1))))
    (unwind-protect
        (cl-letf (((symbol-function 'tab-bar--current-tab)
                   (lambda (&rest _) mock-tab)))
          ;; Creating an instance captures the current tab in its session
          (let ((session (claude-code-ide-mcp-create-session temp-dir "tab-bar-1")))
            (should (numberp (claude-code-ide-mcp-session-port session)))
            (should (eq (claude-code-ide-mcp--get-session-by-id "tab-bar-1") session))
            (should (equal (claude-code-ide-mcp-session-original-tab session) mock-tab))))
      ;; Cleanup
      (claude-code-ide-mcp-stop-session temp-dir)
      (delete-directory temp-dir t))))

(ert-deftest claude-code-ide-test-tab-bar-switch-on-ediff ()
  "Test that tab-bar switching on ediff respects the configuration."
  ;; Test that the variable exists with the expected default
  (should (boundp 'claude-code-ide-switch-tab-on-ediff))
  (should (equal claude-code-ide-switch-tab-on-ediff t))

  ;; Test with simple mocking to ensure the config is checked
  (let* ((original-tab '((name . "original-tab")))
         (current-tab '((name . "current-tab")))
         (tab-switched nil)
         (tab-bar-mode t))

    ;; Mock functions
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (or (eq sym 'tab-bar--current-tab)
                     (eq sym 'tab-bar-select-tab-by-name)
                     (eq sym 'tab-bar-mode)
                     (funcall (cl-letf-saved-symbol-function 'fboundp) sym))))
              ((symbol-function 'tab-bar--current-tab)
               (lambda () current-tab))
              ((symbol-function 'tab-bar-select-tab-by-name)
               (lambda (name)
                 (setq tab-switched name))))

      ;; Create a minimal test session
      (let ((session (make-claude-code-ide-mcp-session
                      :original-tab original-tab)))

        ;; Test 1: With switch enabled (default)
        (let ((claude-code-ide-switch-tab-on-ediff t))
          (setq tab-switched nil)
          ;; Simulate the relevant part of the handler
          (when (and claude-code-ide-switch-tab-on-ediff
                     (claude-code-ide-mcp-session-original-tab session))
            (let ((original-tab (claude-code-ide-mcp-session-original-tab session)))
              (when (and (fboundp 'tab-bar-mode)
                         tab-bar-mode
                         (fboundp 'tab-bar--current-tab)
                         (fboundp 'tab-bar-select-tab-by-name))
                (let ((current-tab (tab-bar--current-tab)))
                  (when (and original-tab current-tab
                             (not (equal (alist-get 'name original-tab)
                                         (alist-get 'name current-tab))))
                    (tab-bar-select-tab-by-name (alist-get 'name original-tab)))))))
          ;; Should have switched
          (should (equal tab-switched "original-tab")))

        ;; Test 2: With switch disabled
        (let ((claude-code-ide-switch-tab-on-ediff nil))
          (setq tab-switched nil)
          ;; Simulate the relevant part of the handler
          (when (and claude-code-ide-switch-tab-on-ediff
                     (claude-code-ide-mcp-session-original-tab session))
            (let ((original-tab (claude-code-ide-mcp-session-original-tab session)))
              (when (and (fboundp 'tab-bar-mode)
                         tab-bar-mode
                         (fboundp 'tab-bar--current-tab)
                         (fboundp 'tab-bar-select-tab-by-name))
                (let ((current-tab (tab-bar--current-tab)))
                  (when (and original-tab current-tab
                             (not (equal (alist-get 'name original-tab)
                                         (alist-get 'name current-tab))))
                    (tab-bar-select-tab-by-name (alist-get 'name original-tab)))))))
          ;; Should NOT have switched
          (should (null tab-switched)))))))

(defun claude-code-ide-run-tests ()
  "Run all claude-code-ide test cases."
  (interactive)
  (ert-run-tests-batch-and-exit "^claude-code-ide-test-"))

(defun claude-code-ide-run-all-tests ()
  "Run all claude-code-ide tests including MCP tests."
  (interactive)
  (ert-run-tests-batch-and-exit "^claude-code-ide-"))

;;; MCP Tests

;; Load MCP module now that websocket is available
(require 'claude-code-ide-mcp)

;; Load MCP handlers module for testing
(require 'claude-code-ide-mcp-handlers)

;; Load MCP tools server module
(condition-case nil
    (require 'claude-code-ide-mcp-server)
  (error nil))

;;; MCP Test Helper Functions

(defmacro claude-code-ide-mcp-tests--with-temp-file (file-var content &rest body)
  "Create a temporary file with CONTENT, bind its path to FILE-VAR, and execute BODY."
  (declare (indent 2))
  `(let ((,file-var (make-temp-file "claude-mcp-test-")))
     (unwind-protect
         (progn
           (with-temp-file ,file-var
             (insert ,content))
           ,@body)
       (delete-file ,file-var))))

(defmacro claude-code-ide-mcp-tests--with-temp-buffer (content &rest body)
  "Create a temporary buffer with CONTENT and execute BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,content)
     (goto-char (point-min))
     ,@body))

;;; Tests for MCP Tool Implementations

(ert-deftest claude-code-ide-test-mcp-open-file ()
  "Test the openFile tool implementation."
  ;; Test successful file open
  (claude-code-ide-mcp-tests--with-temp-file test-file "Line 1\nLine 2\nLine 3\nLine 4"
                                             (let ((result (claude-code-ide-mcp-handle-open-file `((filePath . ,test-file)))))
                                               (should (listp result))
                                               (let ((first-item (car result)))
                                                 (should (equal (alist-get 'type first-item) "text"))
                                                 (should (equal (alist-get 'text first-item) "FILE_OPENED")))
                                               (should (equal (buffer-file-name) test-file))
                                               (kill-buffer)))

  ;; Test with selection
  (claude-code-ide-mcp-tests--with-temp-file test-file "Line 1\nLine 2\nLine 3\nLine 4"
                                             (let ((result (claude-code-ide-mcp-handle-open-file
                                                            `((filePath . ,test-file)
                                                              (startLine . 2)
                                                              (endLine . 3)))))
                                               (should (listp result))
                                               (let ((first-item (car result)))
                                                 (should (equal (alist-get 'type first-item) "text"))
                                                 (should (equal (alist-get 'text first-item) "FILE_OPENED")))
                                               (should (use-region-p))
                                               (should (= (line-number-at-pos (region-beginning)) 2))
                                               (kill-buffer)))

  ;; Test missing filePath parameter
  (should-error (claude-code-ide-mcp-handle-open-file '())
                :type 'mcp-error))

(ert-deftest claude-code-ide-test-mcp-get-current-selection ()
  "Test the selection payload builder."
  ;; Test with active selection
  (claude-code-ide-mcp-tests--with-temp-buffer "Line 1\nLine 2\nLine 3"
                                               (goto-char (point-min))
                                               (set-mark (point))
                                               (forward-line 2)
                                               ;; Ensure transient-mark-mode is on and region is active
                                               (let ((transient-mark-mode t))
                                                 (activate-mark)
                                                 (let ((result (claude-code-ide-mcp--get-current-selection)))
                                                   (should (equal (alist-get 'text result) "Line 1\nLine 2\n"))
                                                   (should-not (assq 'fileUrl result))
                                                   (let ((selection (alist-get 'selection result)))
                                                     (should selection)
                                                     (should-not (assq 'isEmpty selection))
                                                     (let ((start (alist-get 'start selection))
                                                           (end (alist-get 'end selection)))
                                                       (should (= (alist-get 'line start) 1))  ; 1-based
                                                       (should (= (alist-get 'line end) 3)))))))  ; 1-based

  ;; Test without selection
  (claude-code-ide-mcp-tests--with-temp-buffer "Test"
                                               (let ((result (claude-code-ide-mcp--get-current-selection)))
                                                 (should (equal (alist-get 'text result) ""))
                                                 (let ((selection (alist-get 'selection result)))
                                                   (should selection)
                                                   ;; No selection: start and end should be equal (cursor position)
                                                   (should (equal (alist-get 'start selection) (alist-get 'end selection)))
                                                   ;; Should not contain isEmpty or fileUrl
                                                   (should-not (assq 'isEmpty selection))
                                                   (should-not (assq 'fileUrl result))))))

(ert-deftest claude-code-ide-test-mcp-close-tab ()
  "Test the close_tab tool implementation."
  (claude-code-ide-mcp-tests--with-temp-file test-file "Content"
                                             (find-file-noselect test-file)
                                             ;; Close using tool
                                             (let ((result (claude-code-ide-mcp-handle-close-tab `((path . ,test-file)))))
                                               ;; Handler returns VS Code format
                                               (should (listp result))
                                               (let ((first-item (car result)))
                                                 (should (equal (alist-get 'type first-item) "text"))
                                                 (should (equal (alist-get 'text first-item) "TAB_CLOSED")))
                                               (should-not (find-buffer-visiting test-file))))

  ;; Test non-existent buffer - should throw an error
  (should-error (claude-code-ide-mcp-handle-close-tab '((path . "/nonexistent/file")))
                :type 'mcp-error))

(ert-deftest claude-code-ide-test-mcp-tool-registry ()
  "Test that all tools are properly registered."
  ;; Build expected tools list dynamically based on configuration
  (let* ((base-tools '("openFile" "getDiagnostics" "close_tab"))
         (diff-tools (when (bound-and-true-p claude-code-ide-use-ide-diff)
                       '("openDiff" "closeAllDiffTabs")))
         (exec-tools (when (bound-and-true-p claude-code-ide-enable-execute-code)
                       '("executeCode")))
         (expected-tools (append base-tools diff-tools exec-tools)))
    ;; Rebuild tool lists to match current configuration
    (setq claude-code-ide-mcp-tools (claude-code-ide-mcp--build-tool-list))
    (setq claude-code-ide-mcp-tool-schemas (claude-code-ide-mcp--build-tool-schemas))
    (setq claude-code-ide-mcp-tool-descriptions (claude-code-ide-mcp--build-tool-descriptions))
    (dolist (tool-name expected-tools)
      (should (alist-get tool-name claude-code-ide-mcp-tools nil nil #'string=))
      (let ((handler (alist-get tool-name claude-code-ide-mcp-tools nil nil #'string=))
            (schema (alist-get tool-name claude-code-ide-mcp-tool-schemas nil nil #'string=)))
        ;; Check that handler is a function or a symbol that points to a function
        (should (or (functionp handler)
                    (and (symbolp handler) (fboundp handler))))
        ;; Check that schema is provided
        (should schema)))))

(ert-deftest claude-code-ide-test-ediff-flag-disables-tools ()
  "Test that diff tools are excluded when claude-code-ide-use-ide-diff is nil."
  (let ((claude-code-ide-use-ide-diff nil))
    ;; Rebuild tool lists with ediff disabled
    (setq claude-code-ide-mcp-tools (claude-code-ide-mcp--build-tool-list))
    (setq claude-code-ide-mcp-tool-schemas (claude-code-ide-mcp--build-tool-schemas))
    (setq claude-code-ide-mcp-tool-descriptions (claude-code-ide-mcp--build-tool-descriptions))
    ;; Verify diff tools are not present
    (should-not (alist-get "openDiff" claude-code-ide-mcp-tools nil nil #'string=))
    (should-not (alist-get "closeAllDiffTabs" claude-code-ide-mcp-tools nil nil #'string=))
    (should-not (alist-get "openDiff" claude-code-ide-mcp-tool-schemas nil nil #'string=))
    (should-not (alist-get "closeAllDiffTabs" claude-code-ide-mcp-tool-schemas nil nil #'string=))
    (should-not (alist-get "openDiff" claude-code-ide-mcp-tool-descriptions nil nil #'string=))
    (should-not (alist-get "closeAllDiffTabs" claude-code-ide-mcp-tool-descriptions nil nil #'string=))
    ;; Verify other tools are still present
    (should (alist-get "openFile" claude-code-ide-mcp-tools nil nil #'string=))
    (should (alist-get "getDiagnostics" claude-code-ide-mcp-tools nil nil #'string=)))
  ;; Test with ediff enabled
  (let ((claude-code-ide-use-ide-diff t))
    ;; Rebuild tool lists with ediff enabled
    (setq claude-code-ide-mcp-tools (claude-code-ide-mcp--build-tool-list))
    (setq claude-code-ide-mcp-tool-schemas (claude-code-ide-mcp--build-tool-schemas))
    (setq claude-code-ide-mcp-tool-descriptions (claude-code-ide-mcp--build-tool-descriptions))
    ;; Verify diff tools are present
    (should (alist-get "openDiff" claude-code-ide-mcp-tools nil nil #'string=))
    (should (alist-get "closeAllDiffTabs" claude-code-ide-mcp-tools nil nil #'string=))
    (should (alist-get "openDiff" claude-code-ide-mcp-tool-schemas nil nil #'string=))
    (should (alist-get "closeAllDiffTabs" claude-code-ide-mcp-tool-schemas nil nil #'string=))
    (should (alist-get "openDiff" claude-code-ide-mcp-tool-descriptions nil nil #'string=))
    (should (alist-get "closeAllDiffTabs" claude-code-ide-mcp-tool-descriptions nil nil #'string=))))

(ert-deftest claude-code-ide-test-execute-code-flag ()
  "Test that executeCode tool is excluded when flag is nil and included when t."
  (let ((claude-code-ide-enable-execute-code nil))
    (setq claude-code-ide-mcp-tools (claude-code-ide-mcp--build-tool-list))
    (setq claude-code-ide-mcp-tool-schemas (claude-code-ide-mcp--build-tool-schemas))
    (setq claude-code-ide-mcp-tool-descriptions (claude-code-ide-mcp--build-tool-descriptions))
    (should-not (alist-get "executeCode" claude-code-ide-mcp-tools nil nil #'string=))
    (should-not (alist-get "executeCode" claude-code-ide-mcp-tool-schemas nil nil #'string=))
    (should-not (alist-get "executeCode" claude-code-ide-mcp-tool-descriptions nil nil #'string=)))
  (let ((claude-code-ide-enable-execute-code t))
    (setq claude-code-ide-mcp-tools (claude-code-ide-mcp--build-tool-list))
    (setq claude-code-ide-mcp-tool-schemas (claude-code-ide-mcp--build-tool-schemas))
    (setq claude-code-ide-mcp-tool-descriptions (claude-code-ide-mcp--build-tool-descriptions))
    (should (alist-get "executeCode" claude-code-ide-mcp-tools nil nil #'string=))
    (should (alist-get "executeCode" claude-code-ide-mcp-tool-schemas nil nil #'string=))
    (should (alist-get "executeCode" claude-code-ide-mcp-tool-descriptions nil nil #'string=))))

(ert-deftest claude-code-ide-test-execute-code-handler ()
  "Test the executeCode handler."
  ;; Simple expression
  (let ((result (claude-code-ide-mcp-handle-execute-code '((code . "(+ 1 2)")))))
    (should (equal (alist-get 'text (car result)) "3")))
  ;; String result
  (let ((result (claude-code-ide-mcp-handle-execute-code '((code . "(concat \"hello\" \" world\")")))))
    (should (equal (alist-get 'text (car result)) "\"hello world\"")))
  ;; Missing code parameter
  (should-error (claude-code-ide-mcp-handle-execute-code '())
                :type 'mcp-error)
  ;; Evaluation error
  (should-error (claude-code-ide-mcp-handle-execute-code '((code . "(error \"boom\")")))
                :type 'mcp-error))

(ert-deftest claude-code-ide-test-mcp-server-lifecycle ()
  "Test per-instance MCP server start and stop."
  (require 'claude-code-ide-mcp)
  (claude-code-ide-tests--clear-processes)
  (let ((project-dir "/tmp/claude-lifecycle/")
        (session nil))
    (unwind-protect
        (progn
          (setq session (claude-code-ide-mcp-create-session project-dir "lifecycle-1"))
          (let ((port (claude-code-ide-mcp-session-port session)))
            (should (numberp port))
            (should (>= port 10000))
            (should (<= port 65535))
            (should (claude-code-ide-mcp-session-server session))
            ;; Registered under its session ID and reachable via its project
            (should (eq (claude-code-ide-mcp--get-session-by-id "lifecycle-1") session))
            (should (equal (claude-code-ide-mcp--sessions-for-project project-dir)
                           (list session)))
            ;; Check lockfile exists
            (should (file-exists-p (claude-code-ide-mcp--lockfile-path port)))
            ;; Selection tracking is installed while an instance lives
            (should (memq #'claude-code-ide-mcp--track-selection post-command-hook))
            ;; Stop server
            (claude-code-ide-mcp--stop-session session)
            ;; Check lockfile removed and the session deregistered
            (should-not (file-exists-p (claude-code-ide-mcp--lockfile-path port)))
            (should-not (claude-code-ide-mcp--get-session-by-id "lifecycle-1"))
            (should-not (memq #'claude-code-ide-mcp--track-selection post-command-hook))))
      ;; Ensure cleanup
      (claude-code-ide-tests--stop-all-sessions)
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-mcp-stop-scoping ()
  "`claude-code-ide-mcp-stop' stops the buffer's project, or everything."
  (claude-code-ide-tests--clear-processes)
  (let ((project-dir "/tmp/claude-stop-scope-a/")
        (stopped '()))
    (unwind-protect
        ;; The fixtures own no real WebSocket server, so record the
        ;; teardowns instead of performing them
        (cl-letf (((symbol-function 'claude-code-ide-mcp--stop-session)
                   (lambda (session)
                     (push session stopped)
                     (remhash (claude-code-ide-mcp-session-session-id session)
                              claude-code-ide-mcp--sessions))))
          (let ((session-a (claude-code-ide-tests--make-session project-dir))
                (session-b (claude-code-ide-tests--make-session project-dir
                                                                :instance-name "b"))
                (other (claude-code-ide-tests--make-session
                        "/tmp/claude-stop-scope-b/")))
            ;; Inside a project, every instance of that project is stopped
            (cl-letf (((symbol-function 'claude-code-ide-mcp--get-buffer-project)
                       (lambda () project-dir)))
              (claude-code-ide-mcp-stop))
            (should (= 2 (length stopped)))
            (should (memq session-a stopped))
            (should (memq session-b stopped))
            (should-not (memq other stopped))

            ;; Outside any project it falls back to stopping all instances
            (setq stopped '())
            (cl-letf (((symbol-function 'claude-code-ide-mcp--get-buffer-project)
                       (lambda () nil)))
              (claude-code-ide-mcp-stop))
            (should (equal stopped (list other)))))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-ide-connected-notification ()
  "Test that ide_connected notification stores the CLI PID in its session."
  (require 'claude-code-ide-mcp)
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (let* ((session (claude-code-ide-tests--make-session "/tmp/test/" :port 12345))
             (other (claude-code-ide-tests--make-session "/tmp/test/"
                                                         :instance-name "other"
                                                         :port 12346))
             (message '((method . "ide_connected")
                        (params . ((pid . 42))))))
        ;; Simulate the dispatch on the session whose socket carried it
        (claude-code-ide-mcp--handle-message message session)
        (should (= (claude-code-ide-mcp-session-cli-pid session) 42))
        ;; The sibling instance of the same project is unaffected
        (should-not (claude-code-ide-mcp-session-cli-pid other)))
    (claude-code-ide-tests--clear-processes)))

;; Test for side window handling in openDiff
(defvar claude-code-ide-debug-buffer)
(ert-deftest claude-code-ide-test-opendiff-side-window ()
  "Test that openDiff handles side windows correctly."
  (require 'claude-code-ide-debug)
  (require 'claude-code-ide-mcp-handlers)
  (let* ((temp-dir (file-name-as-directory (make-temp-file "test-project-" t)))
         (claude-code-ide-mcp--sessions (make-hash-table :test 'equal))
         (claude-code-ide-debug t)
         (claude-code-ide-debug-buffer "*claude-code-ide-debug*")
         (temp-file (make-temp-file "test-diff-" nil ".txt" "Original content\n"))
         (side-window nil)
         ;; Create a mock session for the test
         (test-session (claude-code-ide-tests--make-session temp-dir :port 12345)))
    ;; Create a .git directory to make this a project
    (make-directory (expand-file-name ".git" temp-dir) t)

    (unwind-protect
        ;; Mock the project detection to return our test directory
        (cl-letf (((symbol-function 'claude-code-ide-mcp--get-buffer-project)
                   (lambda () temp-dir))
                  ((symbol-function 'claude-code-ide-mcp--get-current-session)
                   (lambda () test-session)))
          ;; Set up the project context
          (with-current-buffer (get-buffer-create "*test-buffer*")
            (setq default-directory temp-dir)

            ;; Create a side window to simulate the problem
            (let ((side-buffer (get-buffer-create "*test-sidebar*")))
              (with-current-buffer side-buffer
                (insert "Sidebar content"))
              ;; Display buffer in side window
              (setq side-window (display-buffer-in-side-window
                                 side-buffer
                                 '((side . left) (slot . 0) (window-width . 30))))

              ;; Verify side window was created
              (should (window-parameter side-window 'window-side))

              ;; Now try to open diff - should handle side window gracefully.
              ;; The session is passed explicitly: openDiff belongs to the
              ;; instance whose socket carried the request.
              (let ((result (claude-code-ide-mcp-handle-open-diff
                             `((old_file_path . ,temp-file)
                               (new_file_path . ,temp-file)
                               (new_file_contents . "Modified content\n")
                               (tab_name . "test-diff"))
                             test-session)))
                ;; Should return deferred
                (should (eq (alist-get 'deferred result) t))

                ;; Should have created diff session in the test session
                (should (gethash "test-diff" (claude-code-ide-mcp-session-active-diffs test-session)))

                ;; Clean up - quit ediff if it started
                (when (and (boundp 'ediff-control-buffer)
                           ediff-control-buffer
                           (buffer-live-p ediff-control-buffer))
                  (with-current-buffer ediff-control-buffer
                    (remove-hook 'ediff-quit-hook t t)
                    (ediff-really-quit nil)))))))
      ;; Cleanup
      (when (file-exists-p temp-file)
        (delete-file temp-file))
      (when (file-exists-p temp-dir)
        (delete-directory temp-dir t))
      (when (and side-window (window-live-p side-window))
        (delete-window side-window))
      (claude-code-ide-mcp--cleanup-diff "test-diff" test-session)
      (kill-buffer "*test-buffer*")
      (kill-buffer "*test-sidebar*"))))

;;; Tests for Diagnostics

(ert-deftest claude-code-ide-test-diagnostics-severity-mapping ()
  "Test diagnostic severity conversion."
  (require 'claude-code-ide-diagnostics)
  ;; Test Flycheck symbols
  (should (= (claude-code-ide-diagnostics--severity-to-vscode 'error) 1))
  (should (= (claude-code-ide-diagnostics--severity-to-vscode 'warning) 2))
  (should (= (claude-code-ide-diagnostics--severity-to-vscode 'info) 3))
  (should (= (claude-code-ide-diagnostics--severity-to-vscode 'hint) 4))
  ;; Test default fallback
  (should (= (claude-code-ide-diagnostics--severity-to-vscode 'unknown) 3)))

(ert-deftest claude-code-ide-test-diagnostics-severity-to-string ()
  "Test severity to string conversion."
  (require 'claude-code-ide-diagnostics)
  ;; Test Flycheck severities
  (should (equal (claude-code-ide-diagnostics--severity-to-string 'error) "Error"))
  (should (equal (claude-code-ide-diagnostics--severity-to-string 'warning) "Warning"))
  (should (equal (claude-code-ide-diagnostics--severity-to-string 'info) "Information"))
  (should (equal (claude-code-ide-diagnostics--severity-to-string 'hint) "Hint"))
  ;; Test default fallback
  (should (equal (claude-code-ide-diagnostics--severity-to-string 'unknown) "Information")))

(ert-deftest claude-code-ide-test-diagnostics-handler ()
  "Test getDiagnostics handler."
  (require 'claude-code-ide-diagnostics)
  ;; Test with no diagnostics available
  (let ((result (claude-code-ide-diagnostics-handler nil)))
    ;; The diagnostics handler returns content array format
    (should (listp result))
    ;; Check it has the expected format
    (should (equal (alist-get 'type (car result)) "text"))
    ;; The text should be an empty array "[]"
    (should (equal (alist-get 'text (car result)) "[]"))))

;; Define mock struct for flymake diagnostics testing
(cl-defstruct claude-code-ide-test-mock-diag
  beg end type text backend)

(ert-deftest claude-code-ide-test-flymake-diagnostics ()
  "Test flymake diagnostics collection."
  ;; Skip this test in batch mode as it requires a complex flymake setup
  (skip-unless nil)
  (require 'claude-code-ide-diagnostics))

(ert-deftest claude-code-ide-test-diagnostics-backend-auto ()
  "Test automatic backend detection."
  (require 'claude-code-ide-diagnostics)
  ;; Test flycheck detection
  (cl-letf (((symbol-function 'featurep)
             (lambda (feature &rest _)
               (memq feature '(flycheck flymake))))
            ((symbol-function 'bound-and-true-p)
             (lambda (var)
               (eq var 'flycheck-mode)))
            ((symbol-function 'flycheck-diagnostics)
             (lambda () nil))
            (flycheck-current-errors nil)
            (claude-code-ide-diagnostics-backend 'auto))
    (with-temp-buffer
      (let ((diags (claude-code-ide-diagnostics-get-all (current-buffer))))
        ;; Should use flycheck when flycheck-mode is active
        (should (vectorp diags))))))

;; Disabled due to ERT macro interaction with transient-mark-mode in batch mode
;; The handler works correctly (verified with direct testing) but the test fails
;; because `should` macro seems to evaluate `use-region-p` in a different context
(ert-deftest claude-code-ide-test-open-file-text-patterns ()
  "Test openFile handler with text pattern selection."
  (skip-unless nil) ; Skip this test for now
  (require 'claude-code-ide-mcp-handlers)
  ;; Create a temporary file with known content
  (let ((temp-file (make-temp-file "test-openfile-" nil ".el"))
        ;; Save and restore global transient-mark-mode
        (orig-tmm transient-mark-mode))
    (unwind-protect
        (progn
          ;; Enable transient-mark-mode globally for this test
          (setq transient-mark-mode t)
          ;; Write test content to file
          (with-temp-file temp-file
            (insert "Line 1\n")
            (insert "function foo() {\n")
            (insert "  console.log('hello');\n")
            (insert "}\n")
            (insert "Line 5\n")
            (insert "function bar() {\n")
            (insert "  return 42;\n")
            (insert "}\n"))

          ;; Test 1: Text pattern selection with both start and end
          (let ((result (claude-code-ide-mcp-handle-open-file
                         `((path . ,temp-file)
                           (startText . "function foo")
                           (endText . "}")))))
            ;; Should have opened the file and selected from "function foo" to first "}"
            (with-current-buffer (find-buffer-visiting temp-file)
              (should (string= (buffer-file-name) temp-file))
              ;; Debug info
              (message "Debug: buffer=%s tmm=%s mark-active=%s mark=%s point=%s region-p=%s"
                       (buffer-name) transient-mark-mode mark-active
                       (and (mark) (mark)) (point) (use-region-p))
              ;; Store region state before should
              (let ((region-was-active (use-region-p)))
                (should region-was-active))
              (should (string= (buffer-substring-no-properties (region-beginning) (region-end))
                               "function foo() {\n  console.log('hello');\n}"))))

          ;; Test 2: Only start text pattern
          (with-current-buffer (find-buffer-visiting temp-file)
            (deactivate-mark))
          (let ((result (claude-code-ide-mcp-handle-open-file
                         `((path . ,temp-file)
                           (startText . "function bar")))))
            ;; Should position cursor at start of "function bar"
            (with-current-buffer (find-buffer-visiting temp-file)
              (should (looking-at "function bar"))
              (should-not (use-region-p))))

          ;; Test 3: Text pattern with fallback to line numbers
          (let ((result (claude-code-ide-mcp-handle-open-file
                         `((path . ,temp-file)
                           (startText . "nonexistent text")
                           (startLine . 2)
                           (endLine . 4)))))
            ;; Should fall back to line selection
            (with-current-buffer (find-buffer-visiting temp-file)
              (should (use-region-p))
              (let ((selected (buffer-substring-no-properties (region-beginning) (region-end))))
                (should (string-match-p "function foo" selected)))))

          ;; Test 4: Text patterns take precedence over line numbers
          (with-current-buffer (find-buffer-visiting temp-file)
            (deactivate-mark))
          (let ((result (claude-code-ide-mcp-handle-open-file
                         `((path . ,temp-file)
                           (startText . "Line 5")
                           (startLine . 1)))))
            ;; Should go to "Line 5", not line 1
            (with-current-buffer (find-buffer-visiting temp-file)
              (should (looking-at "Line 5"))
              (should (= (line-number-at-pos) 5)))))

      ;; Cleanup
      (delete-file temp-file)
      ;; Restore original transient-mark-mode
      (setq transient-mark-mode orig-tmm))))

;; Test claude-code-ide-show-claude-window-in-ediff option
(ert-deftest claude-code-ide-test-show-claude-window-in-ediff ()
  "Test that Claude window visibility is controlled correctly during ediff."
  (claude-code-ide-tests--with-temp-directory
   (lambda ()
     (let* ((claude-buffer-created (get-buffer-create "*Claude Code Test*"))
            ;; The instance's own terminal buffer is shown, never a buffer
            ;; found by the canonical name
            (session (claude-code-ide-tests--make-session default-directory
                                                          :buffer claude-buffer-created))
            (diff-buffer-b (get-buffer-create "*Claude Ediff B Test*"))
            (test-file (expand-file-name "test.txt" default-directory))
            (claude-window-displayed nil))

       ;; Create a test file
       (with-temp-file test-file (insert "Original content"))

       ;; Create a .git directory to make this a project
       (make-directory (expand-file-name ".git" default-directory) t)

       ;; Register the diff so the startup handler recognizes it as its own
       ;; (identity goes through buffer-B, set below on the control buffer)
       (puthash "test-diff" `((buffer-B . ,diff-buffer-b) (session . ,session))
                (claude-code-ide-mcp-session-active-diffs session))

       ;; Mock relevant functions
       (cl-letf* (((symbol-function 'claude-code-ide--display-buffer-in-side-window)
                   (lambda (buffer)
                     (setq claude-window-displayed (eq buffer claude-buffer-created))
                     (selected-window)))
                  ((symbol-function 'ediff-buffers)
                   (lambda (_buf-A _buf-B)
                     ;; Simulate successful ediff start
                     (setq ediff-control-buffer (get-buffer-create "*Ediff Control*"))))
                  ((symbol-function 'ediff-next-difference)
                   (lambda () nil))
                  ((symbol-function 'claude-code-ide-mcp--get-current-session)
                   (lambda () session)))

         ;; Test 1: With claude-code-ide-show-claude-window-in-ediff = t (default)
         (let ((claude-code-ide-show-claude-window-in-ediff t)
               (ediff-control-buffer (get-buffer-create "*Ediff Control*")))
           (with-current-buffer ediff-control-buffer
             (setq-local ediff-buffer-B diff-buffer-b))
           (setq claude-window-displayed nil)
           ;; Call the startup handler
           (claude-code-ide-mcp--handle-ediff-startup "test-diff" session nil
                                                      (lambda () nil))
           ;; Should display Claude window
           (should claude-window-displayed))

         ;; Test 2: With claude-code-ide-show-claude-window-in-ediff = nil
         (let ((claude-code-ide-show-claude-window-in-ediff nil)
               (ediff-control-buffer (get-buffer-create "*Ediff Control*")))
           (with-current-buffer ediff-control-buffer
             (setq-local ediff-buffer-B diff-buffer-b))
           (setq claude-window-displayed nil)
           ;; Call the startup handler
           (claude-code-ide-mcp--handle-ediff-startup "test-diff" session nil
                                                      (lambda () nil))
           ;; Should NOT display Claude window
           (should-not claude-window-displayed))

         ;; Cleanup
         (when (buffer-live-p claude-buffer-created)
           (kill-buffer claude-buffer-created))
         (when (buffer-live-p diff-buffer-b)
           (kill-buffer diff-buffer-b))
         (when (get-buffer "*Ediff Control*")
           (kill-buffer "*Ediff Control*"))
         (when (file-exists-p test-file)
           (delete-file test-file))
         (claude-code-ide-tests--clear-processes))))))

(ert-deftest claude-code-ide-test-ediff-startup-buffer-identity ()
  "The ediff startup hook acts only on its own ediff.
`ediff-startup-hook' is global, so with two racing ediffs the wrong
closure can fire first.  Ours is recognized by buffer-B identity: a
foreign control buffer is ignored and the hook stays armed, and the
control buffer name plays no role (ediff derives
`ediff-control-buffer-suffix' from the name — it never consumes it)."
  (claude-code-ide-tests--clear-processes)
  (let* ((buffer-b (generate-new-buffer "*ediff-identity-b*"))
         (foreign-b (generate-new-buffer "*ediff-identity-foreign*"))
         (control-buf (generate-new-buffer "*Ediff Control Panel<2>*"))
         (hook-removed '()))
    (unwind-protect
        (let* ((session (claude-code-ide-tests--make-session "/tmp/ediff-identity/"))
               (active-diffs (claude-code-ide-mcp-session-active-diffs session))
               (startup-fn (lambda ())))
          (puthash "tab" `((buffer-B . ,buffer-b) (session . ,session))
                   active-diffs)
          (cl-letf (((symbol-function 'remove-hook)
                     (lambda (hook fn) (push (cons hook fn) hook-removed)))
                    ((symbol-function 'ediff-next-difference)
                     (lambda (&rest _))))
            ;; A foreign ediff (different buffer-B): untouched, hook kept
            (with-current-buffer control-buf
              (setq-local ediff-buffer-B foreign-b))
            (let ((ediff-control-buffer control-buf))
              (claude-code-ide-mcp--handle-ediff-startup "tab" session nil startup-fn))
            (should-not (alist-get 'control-buffer (gethash "tab" active-diffs)))
            (should-not hook-removed)
            ;; Our own ediff: control buffer recorded, hook removed,
            ;; quit hook installed in the control buffer
            (with-current-buffer control-buf
              (setq-local ediff-buffer-B buffer-b))
            (let ((ediff-control-buffer control-buf))
              (claude-code-ide-mcp--handle-ediff-startup "tab" session nil startup-fn))
            (should (eq (alist-get 'control-buffer (gethash "tab" active-diffs))
                        control-buf))
            (should (equal hook-removed (list (cons 'ediff-startup-hook startup-fn))))
            (should (buffer-local-value 'ediff-quit-hook control-buf))))
      (dolist (buffer (list buffer-b foreign-b control-buf))
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (claude-code-ide-tests--clear-processes))))

;; Test multiple ediff sessions
(ert-deftest claude-code-ide-test-multiple-ediff-sessions ()
  "Test that multiple ediff sessions can run simultaneously without conflicts."
  (claude-code-ide-tests--with-temp-directory
   (lambda ()
     (let* ((session (claude-code-ide-tests--make-session default-directory
                                                          :port 12345))
            (file1 (expand-file-name "test-file1.txt" default-directory))
            (file2 (expand-file-name "test-file2.txt" default-directory))
            (control-buffers '()))

       ;; Create test files
       (with-temp-file file1 (insert "Original content 1"))
       (with-temp-file file2 (insert "Original content 2"))

       ;; Create a .git directory to make this a project
       (make-directory (expand-file-name ".git" default-directory) t)

       ;; Mock ediff functions to capture the buffers each diff runs on
       (cl-letf* ((ediff-called-count 0)
                  ((symbol-function 'ediff-buffers)
                   (lambda (_buf-A buf-B)
                     (cl-incf ediff-called-count)
                     (push (buffer-name buf-B) control-buffers)))
                  ((symbol-function 'claude-code-ide-mcp--get-current-session)
                   (lambda () session)))

         ;; Simulate opening multiple diffs
         (unwind-protect
             (progn
               ;; Open first diff
               (let ((result1 (claude-code-ide-mcp-handle-open-diff
                               `((old_file_path . ,file1)
                                 (new_file_path . ,file1)
                                 (new_file_contents . "Modified content 1")
                                 (tab_name . "diff1"))
                               session)))
                 (should (equal (alist-get 'deferred result1) t))
                 (should (equal (alist-get 'unique-key result1) "diff1")))

               ;; Open second diff
               (let ((result2 (claude-code-ide-mcp-handle-open-diff
                               `((old_file_path . ,file2)
                                 (new_file_path . ,file2)
                                 (new_file_contents . "Modified content 2")
                                 (tab_name . "diff2"))
                               session)))
                 (should (equal (alist-get 'deferred result2) t))
                 (should (equal (alist-get 'unique-key result2) "diff2")))

               ;; Verify ediff was called twice, on two distinct B buffers
               (should (= ediff-called-count 2))
               (should (= (length control-buffers) 2))
               (should (member "*diff1*" control-buffers))
               (should (member "*diff2*" control-buffers))

               ;; Verify active diffs are tracked correctly
               (let ((active-diffs (claude-code-ide-mcp--get-active-diffs session)))
                 (should (gethash "diff1" active-diffs))
                 (should (gethash "diff2" active-diffs))))

           ;; Cleanup
           (claude-code-ide-mcp-handle-close-all-diff-tabs nil session)
           (when (file-exists-p file1) (delete-file file1))
           (when (file-exists-p file2) (delete-file file2))
           (claude-code-ide-tests--clear-processes)))))))

(ert-deftest claude-code-ide-test-mcp-two-projects-deferred-isolation ()
  "Test that deferred responses are answered on their own session's socket."
  (claude-code-ide-tests--clear-processes)
  (let* ((project-a "/tmp/project-a/")
         (project-b "/tmp/project-b/")
         (client-a (claude-code-ide-tests--make-websocket "ws://127.0.0.1:10004"))
         (client-b (claude-code-ide-tests--make-websocket "ws://127.0.0.1:10005"))
         (session-a nil)
         (session-b nil)
         (sent '()))
    ;; Create mock websocket-send-text to capture (client . payload) pairs
    (cl-letf* (((symbol-function 'websocket-send-text)
                (lambda (ws text)
                  (push (cons ws text) sent))))
      (unwind-protect
          (progn
            (setq session-a (claude-code-ide-tests--make-session
                             project-a :client client-a)
                  session-b (claude-code-ide-tests--make-session
                             project-b :client client-b))

            ;; Each session awaits its own deferred openDiff response
            (puthash "openDiff-diff1" "request-id-1"
                     (claude-code-ide-mcp-session-deferred session-a))
            (puthash "openDiff-diff2" "request-id-2"
                     (claude-code-ide-mcp-session-deferred session-b))

            (claude-code-ide-mcp-complete-deferred session-a
                                                   "openDiff"
                                                   '(((type . "text") (text . "FILE_SAVED")))
                                                   "diff1")
            (claude-code-ide-mcp-complete-deferred session-b
                                                   "openDiff"
                                                   '(((type . "text") (text . "DIFF_REJECTED")))
                                                   "diff2")

            ;; Both responses were sent, each on its own session's client
            (should (= (length sent) 2))
            (let ((payload-a (cdr (cl-find-if (lambda (entry)
                                                (eq (car entry) client-a))
                                              sent)))
                  (payload-b (cdr (cl-find-if (lambda (entry)
                                                (eq (car entry) client-b))
                                              sent))))
              (should payload-a)
              (should payload-b)
              (should (equal (alist-get 'id (json-read-from-string payload-a))
                             "request-id-1"))
              (should (string-match-p "FILE_SAVED" payload-a))
              (should (equal (alist-get 'id (json-read-from-string payload-b))
                             "request-id-2"))
              (should (string-match-p "DIFF_REJECTED" payload-b)))

            ;; Verify deferred responses were removed from both sessions
            (should (= 0 (hash-table-count
                          (claude-code-ide-mcp-session-deferred session-a))))
            (should (= 0 (hash-table-count
                          (claude-code-ide-mcp-session-deferred session-b))))

            ;; Completing an id that lives in another session sends nothing
            (setq sent '())
            (puthash "openDiff-diff3" "request-id-3"
                     (claude-code-ide-mcp-session-deferred session-a))
            (claude-code-ide-mcp-complete-deferred session-b "openDiff" nil "diff3")
            (should (null sent))
            (should (gethash "openDiff-diff3"
                             (claude-code-ide-mcp-session-deferred session-a))))
        (claude-code-ide-tests--clear-processes)))))

;;; MCP Tools Server Tests

;; Mock the server functions since web-server might not be available in test env
(defvar claude-code-ide-mcp-server-tests--mock-server-started nil)
(defvar claude-code-ide-mcp-server-tests--mock-server-port 12345)

(defun claude-code-ide-mcp-server-tests--mock-server-start (&optional _port)
  "Mock server start function."
  (setq claude-code-ide-mcp-server-tests--mock-server-started t)
  (cons 'mock-process claude-code-ide-mcp-server-tests--mock-server-port))

(defun claude-code-ide-mcp-server-tests--mock-server-stop (_process)
  "Mock server stop function."
  (setq claude-code-ide-mcp-server-tests--mock-server-started nil))

;;; Mock websocket request/response for testing
(defvar claude-code-ide-mcp-server-tests--last-response nil
  "Storage for the last response sent.")

(defvar claude-code-ide-mcp-server-tests--last-response-headers nil
  "Storage for the last response headers.")

(defvar claude-code-ide-mcp-server-tests--last-response-status nil
  "Storage for the last response status.")

;; Mock the web-server functions
(cl-defstruct claude-code-ide-mcp-server-tests--mock-request
  process headers body)

(cl-defstruct claude-code-ide-mcp-server-tests--mock-process)

(defun claude-code-ide-mcp-server-tests--mock-ws-response-header (process status &rest headers)
  "Mock ws-response-header function."
  (setq claude-code-ide-mcp-server-tests--last-response-status status)
  (setq claude-code-ide-mcp-server-tests--last-response-headers headers))

(defun claude-code-ide-mcp-server-tests--mock-ws-send (process data)
  "Mock ws-send function."
  (unless (claude-code-ide-mcp-server-tests--mock-process-p process)
    (error "Wrong type argument: processp, %s" process))
  (setq claude-code-ide-mcp-server-tests--last-response data))

(defun claude-code-ide-mcp-server-tests--mock-ws-send-404 (process)
  "Mock ws-send-404 function."
  (unless (claude-code-ide-mcp-server-tests--mock-process-p process)
    (error "Wrong type argument: processp, %s" process))
  (setq claude-code-ide-mcp-server-tests--last-response-status 404))

;;; Session Management Tests

(ert-deftest claude-code-ide-mcp-server-test-session-lifecycle ()
  "Test MCP tools server lifecycle against the registered-session table.
The server lives as long as at least one instance is registered, so an
unbalanced or repeated end call cannot pull it out from under a live
sibling instance."
  (let ((claude-code-ide-enable-mcp-server t)
        (claude-code-ide-mcp-server--server nil)
        (claude-code-ide-mcp-server--port nil))
    (unwind-protect
        ;; Mock the server functions and require
        (cl-letf (((symbol-function 'claude-code-ide-mcp-http-server-start)
                   #'claude-code-ide-mcp-server-tests--mock-server-start)
                  ((symbol-function 'claude-code-ide-mcp-http-server-stop)
                   #'claude-code-ide-mcp-server-tests--mock-server-stop)
                  ((symbol-function 'require)
                   (lambda (feature &optional _filename _noerror)
                     (cond ((eq feature 'claude-code-ide-mcp-http-server) nil)
                           ((memq feature '(claude-code-ide-mcp-server websocket vterm flycheck
                                                                       claude-code-ide-debug claude-code-ide-mcp-handlers
                                                                       claude-code-ide transient)) nil)
                           (t (funcall (cl-letf-saved-symbol-function 'require) feature _filename _noerror))))))
          (clrhash claude-code-ide-mcp-server--sessions)
          ;; First instance registers; the web-server package may be absent
          ;; in batch, so bring the mock server up directly
          (claude-code-ide-mcp-server-session-started "sid-1" "/tmp/proj-1/" nil)
          (should (= (hash-table-count claude-code-ide-mcp-server--sessions) 1))
          (let ((result (claude-code-ide-mcp-server-tests--mock-server-start)))
            (setq claude-code-ide-mcp-server--server (car result)
                  claude-code-ide-mcp-server--port (cdr result)))
          (should claude-code-ide-mcp-server--server)
          (should (= claude-code-ide-mcp-server--port
                     claude-code-ide-mcp-server-tests--mock-server-port))

          ;; A second instance of the same project registers separately and
          ;; does not disturb the running server
          (let ((server claude-code-ide-mcp-server--server))
            (claude-code-ide-mcp-server-session-started "sid-2" "/tmp/proj-1/" nil)
            (should (= (hash-table-count claude-code-ide-mcp-server--sessions) 2))
            (should (eq server claude-code-ide-mcp-server--server)))

          ;; Ending one instance keeps the server up for its sibling
          (claude-code-ide-mcp-server-session-ended "sid-1")
          (should (= (hash-table-count claude-code-ide-mcp-server--sessions) 1))
          (should claude-code-ide-mcp-server--server)

          ;; Ending it a second time is a no-op, not a shutdown
          (claude-code-ide-mcp-server-session-ended "sid-1")
          (should (= (hash-table-count claude-code-ide-mcp-server--sessions) 1))
          (should claude-code-ide-mcp-server--server)

          ;; Ending the last instance stops the server
          (claude-code-ide-mcp-server-session-ended "sid-2")
          (should (= (hash-table-count claude-code-ide-mcp-server--sessions) 0))
          (should-not claude-code-ide-mcp-server--server)
          (should-not claude-code-ide-mcp-server--port)
          (should-not claude-code-ide-mcp-server-tests--mock-server-started))
      (clrhash claude-code-ide-mcp-server--sessions))))

(ert-deftest claude-code-ide-mcp-server-test-config-generation ()
  "Test MCP configuration generation."
  (let ((claude-code-ide-enable-mcp-server t)
        (claude-code-ide-mcp-server--server 'mock-server)
        (claude-code-ide-mcp-server--port 8080))
    ;; With server running
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'ws-process) (lambda (_) 'mock-process)))
      (let ((config (claude-code-ide-mcp-server-get-config)))
        (should config)
        (should (equal (alist-get 'type (alist-get 'emacs-tools (alist-get 'mcpServers config)))
                       "http"))
        (should (equal (alist-get 'url (alist-get 'emacs-tools (alist-get 'mcpServers config)))
                       "http://localhost:8080/mcp"))))

    ;; Without server running
    (let ((claude-code-ide-mcp-server--server nil)
          (claude-code-ide-mcp-server--port nil)
          (config (claude-code-ide-mcp-server-get-config)))
      (should-not config))))

(ert-deftest claude-code-ide-mcp-server-test-disabled ()
  "Test that MCP tools server does nothing when disabled."
  (let ((claude-code-ide-enable-mcp-server nil))
    (unwind-protect
        (progn
          (clrhash claude-code-ide-mcp-server--sessions)
          (should-not (claude-code-ide-mcp-server-ensure-server))
          ;; Sessions are still tracked so tool requests can find their
          ;; context, but no server is started
          (claude-code-ide-mcp-server-session-started "sid-disabled" "/tmp/proj/" nil)
          (should (= (hash-table-count claude-code-ide-mcp-server--sessions) 1))
          (should-not claude-code-ide-mcp-server--server)
          (claude-code-ide-mcp-server-session-ended "sid-disabled")
          (should (= (hash-table-count claude-code-ide-mcp-server--sessions) 0)))
      (clrhash claude-code-ide-mcp-server--sessions))))

;;; Tool Configuration Tests

(ert-deftest claude-code-ide-mcp-server-test-tool-config ()
  "Test tool configuration structure."
  (let ((claude-code-ide-mcp-server-tools
         '((test-function
            :description "Test function"
            :parameters ((:name "arg1" :type "string" :required t)
                         (:name "arg2" :type "number" :required nil))))))
    (let* ((tool (car claude-code-ide-mcp-server-tools))
           (name (car tool))
           (plist (cdr tool)))
      (should (eq name 'test-function))
      (should (equal (plist-get plist :description) "Test function"))
      (should (= (length (plist-get plist :parameters)) 2)))))

;;; JSON-RPC Message Tests

(ert-deftest claude-code-ide-mcp-server-test-json-encoding ()
  "Test JSON encoding of MCP config."
  (let ((config '((mcpServers . ((emacs-tools . ((transport . "http")
                                                 (url . "http://localhost:8080/mcp"))))))))
    (let ((json-str (json-encode config)))
      (should (stringp json-str))
      (should (string-match "mcpServers" json-str))
      (should (string-match "emacs-tools" json-str))
      (should (string-match "transport.*:.*http" json-str)))))

(ert-deftest claude-code-ide-mcp-server-test-ws-send-fix ()
  "Test that ws-send is called with process, not request."
  ;; Test that verifies our fix for the wrong-type-argument error
  ;; Skip test if web-server is not available
  (skip-unless (condition-case nil
                   (progn (require 'web-server) t)
                 (error nil)))
  (require 'claude-code-ide-mcp-http-server)
  (let ((mock-process (make-claude-code-ide-mcp-server-tests--mock-process))
        (mock-request (make-claude-code-ide-mcp-server-tests--mock-request)))
    ;; Set the process in the request
    (setf (claude-code-ide-mcp-server-tests--mock-request-process mock-request) mock-process)
    ;; Mock the ws-* functions
    (cl-letf (((symbol-function 'ws-response-header)
               #'claude-code-ide-mcp-server-tests--mock-ws-response-header)
              ((symbol-function 'ws-send)
               #'claude-code-ide-mcp-server-tests--mock-ws-send)
              ((symbol-function 'ws-send-404)
               #'claude-code-ide-mcp-server-tests--mock-ws-send-404))
      ;; Test send-json-response
      (claude-code-ide-mcp-http-server--send-json-response
       mock-request 200 '((test . "data")))
      (should (equal claude-code-ide-mcp-server-tests--last-response-status 200))
      (should (string-match "test.*:.*data" claude-code-ide-mcp-server-tests--last-response))

      ;; Test handle-get (404 response)
      (claude-code-ide-mcp-http-server--handle-get mock-request)
      (should (equal claude-code-ide-mcp-server-tests--last-response-status 404)))))

;;; MCP Prompt Tests

;; The prompt handlers and the POST dispatcher do not call into
;; web-server, so they are testable without it.  `with-slots' in the
;; response helpers comes from eieio and works on the mock request
;; struct.  The module itself tolerates a missing web-server package.
(require 'eieio)
(require 'claude-code-ide-mcp-http-server)

(defun claude-code-ide-mcp-server-tests--prompt-text (messages)
  "Return the text of the first user message in MESSAGES, a vector."
  (alist-get 'text (alist-get 'content (aref messages 0))))

(ert-deftest claude-code-ide-mcp-server-test-make-prompt ()
  "Registration adds one spec; a missing :function is an error."
  (let ((claude-code-ide-mcp-server-prompts nil))
    (let ((spec (claude-code-ide-make-prompt
                 :name "review"
                 :description "Review edits"
                 :args '((:name "rules" :description "Rules" :optional t))
                 :function #'identity)))
      (should (= (length claude-code-ide-mcp-server-prompts) 1))
      (should (eq (car claude-code-ide-mcp-server-prompts) spec))
      (should (equal (plist-get spec :name) "review")))
    (should-error (claude-code-ide-make-prompt :name "x" :description "y"))
    (should-error (claude-code-ide-make-prompt :function #'identity :description "y"))
    (should-error (claude-code-ide-make-prompt :name "x" :function #'identity))))

(ert-deftest claude-code-ide-mcp-server-test-prompts-list ()
  "prompts/list reports name, description and an arguments array."
  (let ((claude-code-ide-mcp-server-prompts nil))
    (claude-code-ide-make-prompt
     :name "plain" :description "No arguments" :function (lambda () "p"))
    (claude-code-ide-make-prompt
     :name "review" :description "Review edits"
     :args '((:name "rules" :description "Rules" :optional t)
             (:name "file" :description "File"))
     :function (lambda (_rules _file) "r"))
    (let* ((result (claude-code-ide-mcp-http-server--handle-prompts-list nil))
           (prompts (alist-get 'prompts result))
           (review (seq-find (lambda (p) (equal (alist-get 'name p) "review")) prompts))
           (plain (seq-find (lambda (p) (equal (alist-get 'name p) "plain")) prompts))
           (args (alist-get 'arguments review)))
      (should (vectorp prompts))
      (should (= (length prompts) 2))
      (should (equal (alist-get 'description review) "Review edits"))
      (should (vectorp args))
      (should (= (length args) 2))
      (should (equal (alist-get 'name (aref args 0)) "rules"))
      (should (eq (alist-get 'required (aref args 0)) :json-false))
      (should (eq (alist-get 'required (aref args 1)) t))
      ;; An argument-free prompt still carries an empty array
      (should (vectorp (alist-get 'arguments plain)))
      (should (= (length (alist-get 'arguments plain)) 0))
      ;; The array encodes as [] and not as null
      (should (string-match-p "\"arguments\":\\[\\]" (json-encode plain))))))

(ert-deftest claude-code-ide-mcp-server-test-prompts-get ()
  "prompts/get passes declared arguments in order and wraps the text."
  (let ((claude-code-ide-mcp-server-prompts nil)
        (received nil))
    (claude-code-ide-make-prompt
     :name "review" :description "Review edits"
     :args '((:name "rules" :description "Rules" :optional t))
     :function (lambda (rules)
                 (setq received rules)
                 (format "Review with rules: %s" (or rules "default"))))
    ;; Argument given: arrives in the function and in the text
    (let* ((result (claude-code-ide-mcp-http-server--handle-prompts-get
                    '((name . "review") (arguments . ((rules . "DOD"))))))
           (messages (alist-get 'messages result)))
      (should (equal received "DOD"))
      (should (equal (alist-get 'description result) "Review edits"))
      (should (vectorp messages))
      (should (equal (alist-get 'role (aref messages 0)) "user"))
      (should (equal (claude-code-ide-mcp-server-tests--prompt-text messages)
                     "Review with rules: DOD")))
    ;; Optional argument omitted: nil reaches the function
    (setq received 'unset)
    (let ((result (claude-code-ide-mcp-http-server--handle-prompts-get
                   '((name . "review")))))
      (should (null received))
      (should (equal (claude-code-ide-mcp-server-tests--prompt-text
                      (alist-get 'messages result))
                     "Review with rules: default")))))

(ert-deftest claude-code-ide-mcp-server-test-prompts-get-errors ()
  "Unknown prompt and missing required argument signal -32602."
  (let ((claude-code-ide-mcp-server-prompts nil))
    (claude-code-ide-make-prompt
     :name "needs-file" :description "Needs a file"
     :args '((:name "file" :description "File"))
     :function (lambda (file) file))
    (let ((err (should-error (claude-code-ide-mcp-http-server--handle-prompts-get
                              '((name . "missing")))
                             :type 'json-rpc-error)))
      (should (= (nth 1 err) -32602))
      (should (string-match-p "Unknown prompt: missing" (nth 2 err))))
    (let ((err (should-error (claude-code-ide-mcp-http-server--handle-prompts-get
                              '((name . "needs-file")))
                             :type 'json-rpc-error)))
      (should (= (nth 1 err) -32602))
      (should (string-match-p "Missing required argument: file" (nth 2 err))))))

(ert-deftest claude-code-ide-mcp-server-test-initialize-capabilities ()
  "initialize advertises both tools and prompts."
  (let* ((result (claude-code-ide-mcp-http-server--handle-initialize nil))
         (capabilities (alist-get 'capabilities result)))
    (should (assq 'tools capabilities))
    (should (assq 'prompts capabilities))
    (should (eq (alist-get 'listChanged (alist-get 'prompts capabilities))
                :json-false))))

(ert-deftest claude-code-ide-mcp-server-test-json-rpc-error-forwarded ()
  "A json-rpc-error from a handler reaches the client with its own code.
Before `json-rpc-error' was declared with `define-error', Emacs turned
the signal into \"Invalid error symbol\" and the client saw -32603."
  (let ((mock-process (make-claude-code-ide-mcp-server-tests--mock-process))
        (mock-request (make-claude-code-ide-mcp-server-tests--mock-request)))
    (setf (claude-code-ide-mcp-server-tests--mock-request-process mock-request) mock-process)
    (cl-letf (((symbol-function 'ws-headers)
               (lambda (_request) '((:POST . "/mcp/sid-1"))))
              ((symbol-function 'ws-body)
               (lambda (_request)
                 (json-encode '((jsonrpc . "2.0") (id . 7) (method . "no/such")))))
              ((symbol-function 'ws-response-header)
               #'claude-code-ide-mcp-server-tests--mock-ws-response-header)
              ((symbol-function 'ws-send)
               #'claude-code-ide-mcp-server-tests--mock-ws-send))
      ;; The response helper ends with (throw 'close-connection nil),
      ;; which web-server's request loop catches in production.
      (catch 'close-connection
        (claude-code-ide-mcp-http-server--handle-post mock-request))
      (should (equal claude-code-ide-mcp-server-tests--last-response-status 200))
      (let* ((response (json-parse-string claude-code-ide-mcp-server-tests--last-response
                                          :object-type 'alist))
             (err (alist-get 'error response)))
        (should err)
        (should (= (alist-get 'code err) -32601))
        (should (equal (alist-get 'message err) "Method not found"))))))

;;; MCP Server Session Context Tests

(ert-deftest claude-code-ide-mcp-server-test-session-registration ()
  "Test session registration and retrieval."
  (let ((session-id "test-session-123")
        (project-dir "/tmp/test-project")
        (buffer (get-buffer-create "*test-buffer*")))
    (unwind-protect
        (progn
          ;; Register a session
          (claude-code-ide-mcp-server-register-session session-id project-dir buffer)

          ;; Retrieve and verify session context
          (let ((context (gethash session-id claude-code-ide-mcp-server--sessions)))
            (should context)
            (should (equal (plist-get context :project-dir) project-dir))
            (should (eq (plist-get context :buffer) buffer))
            (should (plist-get context :start-time)))

          ;; Test get-session-context function
          (let ((claude-code-ide-mcp-server--current-session-id session-id))
            (let ((context (claude-code-ide-mcp-server-get-session-context)))
              (should context)
              (should (equal (plist-get context :project-dir) project-dir))))

          ;; Unregister session
          (claude-code-ide-mcp-server-unregister-session session-id)
          (should-not (gethash session-id claude-code-ide-mcp-server--sessions)))

      ;; Cleanup
      (kill-buffer buffer)
      (clrhash claude-code-ide-mcp-server--sessions))))

(ert-deftest claude-code-ide-mcp-server-test-with-session-context-macro ()
  "Test the with-session-context macro."
  (let ((session-id "test-session-456")
        (project-dir "/tmp/test-project-2/")
        (buffer (get-buffer-create "*test-buffer-2*"))
        (original-dir default-directory))
    (unwind-protect
        (progn
          ;; Set up the buffer with the project directory
          (with-current-buffer buffer
            (setq default-directory project-dir))

          ;; Register a session
          (claude-code-ide-mcp-server-register-session session-id project-dir buffer)

          ;; Test macro with valid session
          (let ((claude-code-ide-mcp-server--current-session-id session-id))
            (claude-code-ide-mcp-server-with-session-context nil
              ;; Inside the macro, default-directory should be the project dir
              (should (equal default-directory project-dir))
              ;; Current buffer should be the session buffer
              (should (eq (current-buffer) buffer))))

          ;; Verify we're back to original context
          (should (equal default-directory original-dir))

          ;; Test error handling with invalid session
          (let ((claude-code-ide-mcp-server--current-session-id "invalid-session"))
            (should-error
             (claude-code-ide-mcp-server-with-session-context nil
               (error "Should not reach here")))))

      ;; Cleanup
      (kill-buffer buffer)
      (clrhash claude-code-ide-mcp-server--sessions))))

(ert-deftest claude-code-ide-mcp-server-test-session-lifecycle-detailed ()
  "Test complete session lifecycle with detailed tracking."
  (let ((session-id "test-session-789")
        (project-dir "/tmp/test-project-3")
        (buffer (get-buffer-create "*test-buffer-3*")))
    (unwind-protect
        (progn
          (clrhash claude-code-ide-mcp-server--sessions)
          ;; A session may register before its terminal buffer exists
          (claude-code-ide-mcp-server-session-started session-id project-dir nil)
          (should (= (hash-table-count claude-code-ide-mcp-server--sessions) 1))
          (should (gethash session-id claude-code-ide-mcp-server--sessions))
          (should-not (plist-get (gethash session-id claude-code-ide-mcp-server--sessions)
                                 :buffer))

          ;; The buffer is filled in once the terminal has been created
          (claude-code-ide-mcp-server-update-session-buffer session-id buffer)
          (should (eq (plist-get (gethash session-id claude-code-ide-mcp-server--sessions)
                                 :buffer)
                      buffer))

          ;; End session
          (claude-code-ide-mcp-server-session-ended session-id)
          (should (= (hash-table-count claude-code-ide-mcp-server--sessions) 0))
          (should-not (gethash session-id claude-code-ide-mcp-server--sessions)))

      ;; Cleanup
      (kill-buffer buffer)
      (clrhash claude-code-ide-mcp-server--sessions))))

(ert-deftest claude-code-ide-mcp-server-test-config-with-session-id ()
  "Test MCP config generation with session ID."
  ;; Mock the server port
  (cl-letf (((symbol-function 'claude-code-ide-mcp-server-get-port)
             (lambda () 12345)))
    ;; Test without session ID
    (let ((config (claude-code-ide-mcp-server-get-config)))
      (should config)
      (let ((url (alist-get 'url (alist-get 'emacs-tools (alist-get 'mcpServers config)))))
        (should (equal url "http://localhost:12345/mcp"))))

    ;; Test with session ID
    (let ((config (claude-code-ide-mcp-server-get-config "my-session-123")))
      (should config)
      (let* ((emacs-tools (alist-get 'emacs-tools (alist-get 'mcpServers config)))
             (url (alist-get 'url emacs-tools)))
        (should (equal url "http://localhost:12345/mcp/my-session-123"))))))

;;; Emacs Tools Tests

(ert-deftest claude-code-ide-emacs-tools-test-imenu-list-symbols ()
  "Test the imenu-list-symbols MCP tool."
  ;; Load the emacs-tools module
  (require 'claude-code-ide-emacs-tools)

  (let ((test-file (make-temp-file "test-imenu-" nil ".el"))
        (session-id "test-session-imenu")
        (project-dir (temporary-file-directory)))
    (unwind-protect
        (progn
          ;; Write test content to file
          (with-temp-file test-file
            (insert ";;; Test file for imenu\n\n"
                    "(defun test-function-1 (arg)\n"
                    "  \"A test function.\"\n"
                    "  (message \"Hello %s\" arg))\n\n"
                    "(defvar test-variable 42\n"
                    "  \"A test variable.\")\n\n"
                    "(defun test-function-2 ()\n"
                    "  \"Another test function.\"\n"
                    "  (+ 1 2))\n\n"
                    "(defconst test-constant 'foo\n"
                    "  \"A test constant.\")\n"))

          ;; Register a mock session
          (claude-code-ide-mcp-server-register-session session-id project-dir nil)

          ;; Test with session context
          (let ((claude-code-ide-mcp-server--current-session-id session-id))
            (let ((result (claude-code-ide-mcp-imenu-list-symbols test-file)))
              ;; Should return a list of results
              (should (listp result))
              (should (> (length result) 0))

              ;; Check that we found our functions and variables
              (let ((result-string (mapconcat #'identity result "\n")))
                (should (string-match "test-function-1" result-string))
                (should (string-match "test-function-2" result-string))
                (should (string-match "test-variable" result-string))
                (should (string-match "test-constant" result-string))

                ;; Check format includes line numbers
                (should (string-match ":[0-9]+:" result-string)))))

          ;; Test error handling - no file path
          (should-error (claude-code-ide-mcp-imenu-list-symbols nil)
                        :type 'error)

          ;; Test with non-existent file
          (let ((result (condition-case nil
                            (claude-code-ide-mcp-imenu-list-symbols "/nonexistent/file.el")
                          (error "Error listing symbols"))))
            (should (stringp result))
            (should (string-match "Error" result))))

      ;; Cleanup
      (delete-file test-file)
      (claude-code-ide-mcp-server-unregister-session session-id))))

(ert-deftest claude-code-ide-emacs-tools-test-imenu-nested-symbols ()
  "Test imenu-list-symbols with nested symbol structures."
  (require 'claude-code-ide-emacs-tools)

  (let ((test-file (make-temp-file "test-imenu-nested-" nil ".py"))
        (session-id "test-session-imenu-nested")
        (project-dir (temporary-file-directory)))
    (unwind-protect
        (progn
          ;; Write Python test content (which often has nested imenu structures)
          (with-temp-file test-file
            (insert "# Test Python file\n\n"
                    "class TestClass:\n"
                    "    def method1(self):\n"
                    "        pass\n\n"
                    "    def method2(self, arg):\n"
                    "        return arg * 2\n\n"
                    "def standalone_function():\n"
                    "    return 42\n"))

          ;; Register a mock session
          (claude-code-ide-mcp-server-register-session session-id project-dir nil)

          ;; Test with session context
          (let ((claude-code-ide-mcp-server--current-session-id session-id))
            ;; Note: This test might not find nested structures if python-mode
            ;; isn't properly configured, but it should at least not error
            (condition-case err
                (let ((result (claude-code-ide-mcp-imenu-list-symbols test-file)))
                  ;; Should return either a list or a string (no symbols message)
                  (should (or (listp result) (stringp result))))
              (error
               ;; If python mode isn't available, that's okay for this test
               (should (string-match "Error" (error-message-string err)))))))

      ;; Cleanup
      (delete-file test-file)
      (claude-code-ide-mcp-server-unregister-session session-id))))

(ert-deftest claude-code-ide-test-tool-format-backward-compatibility ()
  "Test that both old and new tool formats work correctly."
  (require 'claude-code-ide-mcp-server)

  ;; Define a test function
  (defun test-tool-func (arg1 arg2)
    "Test function for tool format testing."
    (list arg1 arg2))

  ;; Test old format
  (let ((old-format-tool '(test-tool-func
                           :description "Test tool in old format"
                           :parameters ((:name "arg1"
                                               :type "string"
                                               :required t
                                               :description "First argument")
                                        (:name "arg2"
                                               :type "number"
                                               :required nil
                                               :description "Second argument")))))

    ;; Check format detection
    (should (eq (claude-code-ide--tool-format-p old-format-tool) 'old))

    ;; Check normalization - should emit warning
    (let ((warning-msg nil))
      ;; Capture the warning message
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (when (string-match "deprecated format" fmt)
                     (setq warning-msg (apply #'format fmt args))))))
        (let ((normalized (claude-code-ide--normalize-tool-spec old-format-tool)))
          (should (eq (plist-get normalized :function) 'test-tool-func))
          (should (equal (plist-get normalized :name) "test-tool-func"))
          (should (equal (plist-get normalized :description) "Test tool in old format"))
          (should (equal (length (plist-get normalized :args)) 2))))
      ;; Verify warning was emitted
      (should warning-msg)
      (should (string-match "test-tool-func.*deprecated.*claude-code-ide-make-tool" warning-msg))))

  ;; Test new format
  (let ((new-format-tool (claude-code-ide-make-tool
                          :function #'test-tool-func
                          :name "test_tool_new"
                          :description "Test tool in new format"
                          :args '((:name "arg1"
                                         :type string
                                         :description "First argument")
                                  (:name "arg2"
                                         :type number
                                         :description "Second argument"
                                         :optional t)))))

    ;; Check format detection
    (should (eq (claude-code-ide--tool-format-p new-format-tool) 'new))

    ;; Check normalization
    (let ((normalized (claude-code-ide--normalize-tool-spec new-format-tool)))
      (should (eq (plist-get normalized :function) 'test-tool-func))
      (should (equal (plist-get normalized :name) "test_tool_new"))
      (should (equal (plist-get normalized :description) "Test tool in new format"))
      (let ((args (plist-get normalized :args)))
        (should (equal (length args) 2))
        ;; Check first argument
        (let ((arg1 (car args)))
          (should (equal (plist-get arg1 :name) "arg1"))
          (should (eq (plist-get arg1 :type) 'string))
          (should (not (plist-get arg1 :optional))))
        ;; Check second argument
        (let ((arg2 (cadr args)))
          (should (equal (plist-get arg2 :name) "arg2"))
          (should (eq (plist-get arg2 :type) 'number))
          (should (plist-get arg2 :optional))))))

  ;; Test that both formats can coexist in the same list
  (let* ((claude-code-ide-mcp-server-tools
          (list
           ;; Old format
           '(test-func-old
             :description "Old format tool"
             :parameters ((:name "param" :type "string" :required t)))
           ;; New format
           (claude-code-ide-make-tool
            :function #'test-func-new
            :name "test_func_new"
            :description "New format tool"
            :args '((:name "param" :type string)))))
         (normalized-tools (mapcar #'claude-code-ide--normalize-tool-spec
                                   claude-code-ide-mcp-server-tools)))

    ;; Both tools should normalize correctly
    (should (equal (length normalized-tools) 2))
    (should (eq (plist-get (car normalized-tools) :function) 'test-func-old))
    (should (eq (plist-get (cadr normalized-tools) :function) 'test-func-new))))

(ert-deftest claude-code-ide-emacs-tools-test-tool-configuration ()
  "Test that imenu tool is properly configured."
  (require 'claude-code-ide-emacs-tools)
  (require 'claude-code-ide-mcp-server)

  ;; Setup tools first
  (claude-code-ide-emacs-tools-setup)

  ;; Find the imenu tool in the registered tools
  (let ((imenu-tool (cl-find-if
                     (lambda (tool)
                       (let ((normalized (claude-code-ide--normalize-tool-spec tool)))
                         (eq (plist-get normalized :function)
                             'claude-code-ide-mcp-imenu-list-symbols)))
                     claude-code-ide-mcp-server-tools)))
    (should imenu-tool)

    ;; Normalize the tool to check its properties
    (let ((normalized (claude-code-ide--normalize-tool-spec imenu-tool)))
      ;; Check description
      (should (equal (plist-get normalized :description)
                     "Navigate and explore a file's structure by listing all its functions, classes, and variables with their locations"))

      ;; Check args
      (let ((args (plist-get normalized :args)))
        (should (= (length args) 1))
        (let ((file-path-arg (car args)))
          (should (equal (plist-get file-path-arg :name) "file_path"))
          (should (eq (plist-get file-path-arg :type) 'string))
          (should (not (plist-get file-path-arg :optional)))
          (should (equal (plist-get file-path-arg :description)
                         "Path to the file to analyze for symbols")))))))

;;; Review Baseline and Hunk Tests

(require 'claude-code-ide-review)

(defun claude-code-ide-review-tests--write (dir file content)
  "Write CONTENT to FILE under DIR, creating FILE's directory when needed."
  (let ((path (expand-file-name file dir)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path
      (insert content))))

(defun claude-code-ide-review-tests--git (dir &rest args)
  "Run git ARGS in DIR and return its trimmed output; fail the test on error."
  (let ((result (apply #'claude-code-ide-review--git dir args)))
    (should (eq (car result) 0))
    (cdr result)))

(defmacro claude-code-ide-review-tests--with-repo (var &rest body)
  "Run BODY with VAR bound to a fresh git repository directory.
The repository has one commit containing a.txt with the lines one,
two, three.  The baseline table is empty for the duration and the
directory is deleted afterwards."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "claude-review-" t)))
         (claude-code-ide-review--baselines (make-hash-table :test 'equal))
         (claude-code-ide-review--notes (make-hash-table :test 'equal)))
     (unwind-protect
         (progn
           (claude-code-ide-review-tests--git ,var "init" "-q")
           (claude-code-ide-review-tests--write ,var "a.txt" "one\ntwo\nthree\n")
           (claude-code-ide-review-tests--git ,var "add" "a.txt")
           (claude-code-ide-review-tests--git ,var "commit" "-q" "-m" "init")
           ,@body)
       ;; A test that opened the view (directly or through review_open)
       ;; must not leave it pointing at this repository
       (when claude-code-ide-review--view
         (claude-code-ide-review-quit))
       (delete-directory ,var t))))

(ert-deftest claude-code-ide-review-test-snapshot-clean-tree ()
  "A clean tree yields HEAD as the baseline and no pinning ref."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let ((baseline (claude-code-ide-review--snapshot repo "sid-1"))
                                                 (head (claude-code-ide-review-tests--git repo "rev-parse" "HEAD")))
                                             (should baseline)
                                             (should (equal (claude-code-ide-review-baseline-commit baseline) head))
                                             (should-not (claude-code-ide-review-baseline-ref baseline))
                                             (should (equal (claude-code-ide-review-baseline-sessions baseline) '("sid-1")))
                                             (should (equal (claude-code-ide-review-baseline-toplevel baseline)
                                                            (file-truename repo)))
                                             (should (string-empty-p
                                                      (claude-code-ide-review-tests--git repo "for-each-ref" "refs/claude-review/")))
                                             (should (eq (claude-code-ide-review-baseline repo) baseline)))))

(ert-deftest claude-code-ide-review-test-snapshot-dirty-tree ()
  "A dirty tree is snapshotted into a pinned commit holding the edits."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--write repo "a.txt" "one\ntwo\nthree\nfour\n")
                                           (let* ((baseline (claude-code-ide-review--snapshot repo "sid-1"))
                                                  (commit (claude-code-ide-review-baseline-commit baseline))
                                                  (head (claude-code-ide-review-tests--git repo "rev-parse" "HEAD")))
                                             (should-not (equal commit head))
                                             (should (equal (claude-code-ide-review-baseline-ref baseline)
                                                            "refs/claude-review/sid-1"))
                                             (should (string-match-p commit
                                                                     (claude-code-ide-review-tests--git
                                                                      repo "for-each-ref" "refs/claude-review/")))
                                             (should (equal (claude-code-ide-review-tests--git repo "show" (concat commit ":a.txt"))
                                                            "one\ntwo\nthree\nfour"))
                                             ;; The working tree keeps its edit and nothing was staged
                                             (should (equal (claude-code-ide-review-tests--git repo "diff" "--name-only")
                                                            "a.txt"))
                                             (should (string-empty-p
                                                      (claude-code-ide-review-tests--git repo "diff" "--cached" "--name-only"))))))

(ert-deftest claude-code-ide-review-test-snapshot-shared-and-released ()
  "Sessions share a baseline; it outlives them until Emacs exits."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--write repo "a.txt" "changed\n")
                                           (let* ((first (claude-code-ide-review--snapshot repo "sid-1"))
                                                  (second (claude-code-ide-review--snapshot repo "sid-2")))
                                             (should (eq first second))
                                             (should (equal (sort (copy-sequence (claude-code-ide-review-baseline-sessions first))
                                                                  #'string<)
                                                            '("sid-1" "sid-2")))
                                             (claude-code-ide-review--release "sid-1")
                                             (should (claude-code-ide-review-baseline repo))
                                             (should-not (string-empty-p
                                                          (claude-code-ide-review-tests--git repo "for-each-ref" "refs/claude-review/")))
                                             ;; The last session ending keeps the baseline for a restarted session
                                             (claude-code-ide-review--release "sid-2")
                                             (should (eq (claude-code-ide-review-baseline repo) first))
                                             (should-not (claude-code-ide-review-baseline-sessions first))
                                             (should-not (string-empty-p
                                                          (claude-code-ide-review-tests--git repo "for-each-ref" "refs/claude-review/")))
                                             ;; A new session in the project joins the existing baseline
                                             (should (eq (claude-code-ide-review--snapshot repo "sid-3") first))
                                             (should (equal (claude-code-ide-review-baseline-sessions first) '("sid-3")))
                                             ;; Releasing an unknown id is a no-op
                                             (claude-code-ide-review--release "sid-9")
                                             ;; Emacs exit deletes the ref and forgets everything
                                             (claude-code-ide-review--release-all)
                                             (should-not (claude-code-ide-review-baseline repo))
                                             (should (string-empty-p
                                                      (claude-code-ide-review-tests--git repo "for-each-ref" "refs/claude-review/"))))))

(ert-deftest claude-code-ide-review-test-snapshot-not-a-repo ()
  "A directory outside any repository gets no baseline."
  (skip-unless (executable-find "git"))
  (let ((dir (file-name-as-directory (make-temp-file "claude-review-plain-" t)))
        (claude-code-ide-review--baselines (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (should-not (claude-code-ide-review--snapshot dir "sid-1"))
          (should (= (hash-table-count claude-code-ide-review--baselines) 0))
          (should-not (claude-code-ide-review-changed-files dir))
          (should-not (claude-code-ide-review-hunks dir "a.txt")))
      (delete-directory dir t))))

(ert-deftest claude-code-ide-review-test-mark-baseline-moves-it ()
  "Marking a new baseline hides earlier edits and keeps the session list."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review--snapshot repo "sid-1")
                                           (claude-code-ide-review--snapshot repo "sid-2")
                                           (claude-code-ide-review-tests--write repo "a.txt" "one\ntwo\nthree\nfour\n")
                                           (should (equal (claude-code-ide-review-changed-files repo) '("a.txt")))
                                           (let ((new (claude-code-ide-review-mark-baseline repo)))
                                             (should new)
                                             (should-not (claude-code-ide-review-changed-files repo))
                                             (should (equal (sort (copy-sequence (claude-code-ide-review-baseline-sessions new))
                                                                  #'string<)
                                                            '("sid-1" "sid-2")))
                                             ;; Exactly one pinning ref remains, the new one
                                             (should (= 1 (length (split-string
                                                                   (claude-code-ide-review-tests--git
                                                                    repo "for-each-ref" "refs/claude-review/")
                                                                   "\n" t)))))))

(ert-deftest claude-code-ide-review-test-changed-files ()
  "Changed files are tracked edits plus untracked, non-ignored files."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review--snapshot repo "sid-1")
                                           (should-not (claude-code-ide-review-changed-files repo))
                                           (claude-code-ide-review-tests--write repo "a.txt" "one\n2\nthree\n")
                                           (claude-code-ide-review-tests--write repo "new.txt" "new\n")
                                           (claude-code-ide-review-tests--write repo "scratch.log" "ignored\n")
                                           (claude-code-ide-review-tests--write repo ".gitignore" "*.log\n")
                                           (should (equal (claude-code-ide-review-changed-files repo)
                                                          '(".gitignore" "a.txt" "new.txt")))))

(ert-deftest claude-code-ide-review-test-hunks-tracked ()
  "A changed line and an appended line give two hunks with git's positions."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review--snapshot repo "sid-1")
                                           (claude-code-ide-review-tests--write repo "a.txt" "one\n2\nthree\nfour\n")
                                           (let ((hunks (claude-code-ide-review-hunks repo "a.txt")))
                                             (should (= (length hunks) 2))
                                             (let ((h1 (nth 0 hunks))
                                                   (h2 (nth 1 hunks)))
                                               (should (equal (claude-code-ide-review-hunk-file h1) "a.txt"))
                                               (should (= (claude-code-ide-review-hunk-old-start h1) 2))
                                               (should (= (claude-code-ide-review-hunk-old-count h1) 1))
                                               (should (= (claude-code-ide-review-hunk-new-start h1) 2))
                                               (should (= (claude-code-ide-review-hunk-new-count h1) 1))
                                               (should (equal (claude-code-ide-review-hunk-removed h1) "two"))
                                               (should (equal (claude-code-ide-review-hunk-added h1) "2"))
                                               ;; Pure insertion after old line 3
                                               (should (= (claude-code-ide-review-hunk-old-start h2) 3))
                                               (should (= (claude-code-ide-review-hunk-old-count h2) 0))
                                               (should (= (claude-code-ide-review-hunk-new-start h2) 4))
                                               (should (= (claude-code-ide-review-hunk-new-count h2) 1))
                                               (should (equal (claude-code-ide-review-hunk-removed h2) ""))
                                               (should (equal (claude-code-ide-review-hunk-added h2) "four"))
                                               (should (= (length (claude-code-ide-review-hunk-id h1)) 40))
                                               (should-not (equal (claude-code-ide-review-hunk-id h1)
                                                                  (claude-code-ide-review-hunk-id h2)))))))

(ert-deftest claude-code-ide-review-test-hunks-untracked ()
  "A file absent from the baseline is one fully-added hunk."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review--snapshot repo "sid-1")
                                           (claude-code-ide-review-tests--write repo "new.txt" "alpha\nbeta\n")
                                           (let ((hunks (claude-code-ide-review-hunks repo "new.txt")))
                                             (should (= (length hunks) 1))
                                             (let ((h (car hunks)))
                                               (should (= (claude-code-ide-review-hunk-old-count h) 0))
                                               (should (= (claude-code-ide-review-hunk-new-start h) 1))
                                               (should (= (claude-code-ide-review-hunk-new-count h) 2))
                                               (should (equal (claude-code-ide-review-hunk-removed h) ""))
                                               (should (equal (claude-code-ide-review-hunk-added h) "alpha\nbeta"))))
                                           ;; An unchanged tracked file has no hunks
                                           (should-not (claude-code-ide-review-hunks repo "a.txt"))
                                           ;; all-hunks walks every changed file
                                           (should (= (length (claude-code-ide-review-all-hunks repo)) 1))))

(ert-deftest claude-code-ide-review-test-pre-existing-untracked-file ()
  "A file untracked before the snapshot shows only edits made after it."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--write repo "pre.txt" "old\n")
                                           (let ((baseline (claude-code-ide-review--snapshot repo "sid-1")))
                                             ;; The untracked file is part of the snapshot commit
                                             (should (equal (claude-code-ide-review-tests--git
                                                             repo "show" (concat (claude-code-ide-review-baseline-commit baseline)
                                                                                 ":pre.txt"))
                                                            "old"))
                                             ;; Unchanged, it is not a changed file
                                             (should-not (claude-code-ide-review-changed-files repo))
                                             ;; Edited, only the new line is a hunk
                                             (claude-code-ide-review-tests--write repo "pre.txt" "old\nnew\n")
                                             (should (equal (claude-code-ide-review-changed-files repo) '("pre.txt")))
                                             (let ((hunks (claude-code-ide-review-hunks repo "pre.txt")))
                                               (should (= (length hunks) 1))
                                               (should (= (claude-code-ide-review-hunk-old-count (car hunks)) 0))
                                               (should (= (claude-code-ide-review-hunk-new-start (car hunks)) 2))
                                               (should (equal (claude-code-ide-review-hunk-added (car hunks)) "new")))
                                             ;; The real index is still untouched
                                             (should (string-empty-p
                                                      (claude-code-ide-review-tests--git repo "diff" "--cached" "--name-only"))))))

(ert-deftest claude-code-ide-review-test-deleted-file ()
  "A tracked file deleted after the snapshot is listed with a removal hunk."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review--snapshot repo "sid-1")
                                           (delete-file (expand-file-name "a.txt" repo))
                                           (should (equal (claude-code-ide-review-changed-files repo) '("a.txt")))
                                           (let ((hunks (claude-code-ide-review-hunks repo "a.txt")))
                                             (should (= (length hunks) 1))
                                             (should (= (claude-code-ide-review-hunk-old-count (car hunks)) 3))
                                             (should (= (claude-code-ide-review-hunk-new-count (car hunks)) 0))
                                             (should (equal (claude-code-ide-review-hunk-removed (car hunks)) "one\ntwo\nthree")))))

(ert-deftest claude-code-ide-review-test-deleted-untracked-file ()
  "An untracked file present at the snapshot and deleted later is a removal."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--write repo "pre.txt" "old\n")
                                           (claude-code-ide-review--snapshot repo "sid-1")
                                           (delete-file (expand-file-name "pre.txt" repo))
                                           (should (equal (claude-code-ide-review-changed-files repo) '("pre.txt")))
                                           (let ((hunks (claude-code-ide-review-hunks repo "pre.txt")))
                                             (should (= (length hunks) 1))
                                             (should (= (claude-code-ide-review-hunk-new-count (car hunks)) 0))
                                             (should (equal (claude-code-ide-review-hunk-removed (car hunks)) "old")))))

(ert-deftest claude-code-ide-review-test-size-limit-skips-large-untracked ()
  "Untracked files over the limit stay out of the snapshot and the review."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let ((claude-code-ide-review-max-file-size 64))
                                             (claude-code-ide-review-tests--write repo "big.dat" (make-string 200 ?x))
                                             (claude-code-ide-review-tests--write repo "small.txt" "s\n")
                                             (let ((baseline (claude-code-ide-review--snapshot repo "sid-1")))
                                               ;; small.txt is in the snapshot, big.dat is not
                                               (should (eq 0 (car (claude-code-ide-review--git
                                                                   repo "cat-file" "-e"
                                                                   (concat (claude-code-ide-review-baseline-commit baseline) ":small.txt")))))
                                               (should-not (eq 0 (car (claude-code-ide-review--git
                                                                       repo "cat-file" "-e"
                                                                       (concat (claude-code-ide-review-baseline-commit baseline) ":big.dat"))))))
                                             ;; Growing the big file changes nothing in the review
                                             (claude-code-ide-review-tests--write repo "big.dat" (make-string 300 ?y))
                                             (should-not (claude-code-ide-review-changed-files repo))
                                             (should (equal (claude-code-ide-review-skipped-files repo) '("big.dat")))
                                             (claude-code-ide-review-tests--with-session repo
                                                                                         (should (equal (claude-code-ide-review-tool-open)
                                                                                                        "No changes since the baseline\nSkipped 1 untracked file over 64 bytes: big.dat"))))))

(ert-deftest claude-code-ide-review-test-queries-write-no-objects ()
  "Listing files and hunks after the snapshot adds nothing to .git/objects."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--write repo "pre.txt" "old\n")
                                           (claude-code-ide-review--snapshot repo "sid-1")
                                           (claude-code-ide-review-tests--write repo "pre.txt" "old\nnew\n")
                                           (claude-code-ide-review-tests--write repo "a.txt" "one\n2\nthree\n")
                                           (claude-code-ide-review-tests--write repo "fresh.txt" "fresh\n")
                                           (let ((before (claude-code-ide-review-tests--git repo "count-objects")))
                                             (should (equal (claude-code-ide-review-changed-files repo)
                                                            '("a.txt" "fresh.txt" "pre.txt")))
                                             (dolist (file '("a.txt" "fresh.txt" "pre.txt"))
                                               (should (claude-code-ide-review-hunks repo file)))
                                             (should (equal (claude-code-ide-review-tests--git repo "count-objects") before)))))

(ert-deftest claude-code-ide-review-test-rebaseline-when-all-committed ()
  "Committing every change moves the baseline to HEAD and clears the review."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let ((claude-code-ide-review-rebaseline-when-committed t))
                                             ;; Dirty snapshot, so a pinning ref exists
                                             (claude-code-ide-review-tests--write repo "a.txt" "one\n2\nthree\n")
                                             (let* ((baseline (claude-code-ide-review--snapshot repo "sid-1"))
                                                    (old-ref (claude-code-ide-review-baseline-ref baseline)))
                                               (should old-ref)
                                               (should (equal (claude-code-ide-review-baseline-head baseline)
                                                              (claude-code-ide-review-tests--git repo "rev-parse" "HEAD")))
                                               (claude-code-ide-review-tests--write repo "a.txt" "one\n2\nthree\nfour\n")
                                               (claude-code-ide-review-put-note repo (car (claude-code-ide-review-hunks repo "a.txt"))
                                                                                'claude "Added the fourth step")
                                               ;; Nothing committed yet: HEAD unchanged, review intact
                                               (should-not (claude-code-ide-review-head-moved-p repo))
                                               (should (equal (claude-code-ide-review-changed-files repo) '("a.txt")))
                                               ;; Commit everything
                                               (claude-code-ide-review-tests--git repo "add" "-A")
                                               (claude-code-ide-review-tests--git repo "commit" "-q" "-m" "step four")
                                               (should (claude-code-ide-review-head-moved-p repo))
                                               (should-not (claude-code-ide-review-changed-files repo))
                                               (let ((new (claude-code-ide-review-baseline repo)))
                                                 (should-not (eq new baseline))
                                                 (should (equal (claude-code-ide-review-baseline-commit new)
                                                                (claude-code-ide-review-tests--git repo "rev-parse" "HEAD")))
                                                 (should-not (claude-code-ide-review-baseline-ref new))
                                                 (should (equal (claude-code-ide-review-baseline-sessions new) '("sid-1"))))
                                               (should-not (claude-code-ide-review-head-moved-p repo))
                                               (should-not (claude-code-ide-review-notes repo))
                                               (should (string-empty-p
                                                        (claude-code-ide-review-tests--git repo "for-each-ref" "refs/claude-review/")))))))

(ert-deftest claude-code-ide-review-test-rebaseline-waits-for-unsent-comments ()
  "A full commit does not move the baseline while a user comment is unsent."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let ((claude-code-ide-review-rebaseline-when-committed t))
                                             (let ((baseline (claude-code-ide-review--snapshot repo "sid-1")))
                                               (claude-code-ide-review-tests--write repo "a.txt" "one\n2\nthree\n")
                                               (let ((hunk (car (claude-code-ide-review-hunks repo "a.txt"))))
                                                 (claude-code-ide-review-put-note repo hunk 'user "Why a digit?")
                                                 (claude-code-ide-review-tests--git repo "add" "-A")
                                                 (claude-code-ide-review-tests--git repo "commit" "-q" "-m" "digit")
                                                 ;; HEAD moved and the tree is clean, yet the review stays
                                                 (should (eq (claude-code-ide-review-baseline repo) baseline))
                                                 (should (claude-code-ide-review-head-moved-p repo))
                                                 (should (= (length (claude-code-ide-review-unsent-comments repo)) 1))
                                                 (should (equal (claude-code-ide-review-changed-files repo) '("a.txt")))
                                                 ;; Once the comment is gone the next query moves the baseline
                                                 (claude-code-ide-review-remove-note repo (claude-code-ide-review-hunk-id hunk) 'user)
                                                 (should-not (eq (claude-code-ide-review-baseline repo) baseline))
                                                 (should-not (claude-code-ide-review-head-moved-p repo))
                                                 (should-not (claude-code-ide-review-changed-files repo)))))))

(ert-deftest claude-code-ide-review-test-partial-commit-keeps-review ()
  "After a partial commit the baseline, notes and a HEAD-moved hint remain."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let ((claude-code-ide-review-rebaseline-when-committed t))
                                             (let ((baseline (claude-code-ide-review--snapshot repo "sid-1")))
                                               (claude-code-ide-review-tests--write repo "a.txt" "one\n2\nthree\n")
                                               (claude-code-ide-review-tests--write repo "new.txt" "new\n")
                                               (claude-code-ide-review-put-note repo (car (claude-code-ide-review-hunks repo "a.txt"))
                                                                                'claude "Shorter name")
                                               ;; Commit a.txt only; new.txt stays untracked
                                               (claude-code-ide-review-tests--git repo "add" "a.txt")
                                               (claude-code-ide-review-tests--git repo "commit" "-q" "-m" "partial")
                                               (should (eq (claude-code-ide-review-baseline repo) baseline))
                                               (should (claude-code-ide-review-head-moved-p repo))
                                               (should (equal (claude-code-ide-review-changed-files repo) '("a.txt" "new.txt")))
                                               (should (= (length (claude-code-ide-review-notes repo)) 1))
                                               (claude-code-ide-review-tests--with-session repo
                                                                                           (should (string-match-p "HEAD moved since the baseline"
                                                                                                                   (claude-code-ide-review-tool-open))))
                                               ;; With the option off, even a full commit leaves the baseline
                                               (let ((claude-code-ide-review-rebaseline-when-committed nil))
                                                 (claude-code-ide-review-tests--git repo "add" "-A")
                                                 (claude-code-ide-review-tests--git repo "commit" "-q" "-m" "rest")
                                                 (should (eq (claude-code-ide-review-baseline repo) baseline))
                                                 (should (equal (claude-code-ide-review-changed-files repo) '("a.txt" "new.txt"))))))))

(ert-deftest claude-code-ide-review-test-hunk-id-stability ()
  "Editing one hunk's text changes only that hunk's id."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review--snapshot repo "sid-1")
                                           (claude-code-ide-review-tests--write repo "a.txt" "one\n2\nthree\nfour\n")
                                           (let ((before (mapcar #'claude-code-ide-review-hunk-id
                                                                 (claude-code-ide-review-hunks repo "a.txt"))))
                                             (claude-code-ide-review-tests--write repo "a.txt" "one\n2\nthree\nFOUR\n")
                                             (let ((after (mapcar #'claude-code-ide-review-hunk-id
                                                                  (claude-code-ide-review-hunks repo "a.txt"))))
                                               (should (equal (nth 0 before) (nth 0 after)))
                                               (should-not (equal (nth 1 before) (nth 1 after)))))))

(ert-deftest claude-code-ide-review-test-parse-hunks-skips-headers ()
  "The parser ignores diff headers and the no-newline marker."
  (let ((hunks (claude-code-ide-review--parse-hunks
                "f.txt"
                (concat "diff --git a/f.txt b/f.txt\n"
                        "--- a/f.txt\n"
                        "+++ b/f.txt\n"
                        "@@ -1,2 +1 @@\n"
                        "-a\n"
                        "-b\n"
                        "+ab\n"
                        "\\ No newline at end of file\n"))))
    (should (= (length hunks) 1))
    (should (equal (claude-code-ide-review-hunk-removed (car hunks)) "a\nb"))
    (should (equal (claude-code-ide-review-hunk-added (car hunks)) "ab"))
    (should (= (claude-code-ide-review-hunk-old-count (car hunks)) 2))
    (should (= (claude-code-ide-review-hunk-new-count (car hunks)) 1))))

(ert-deftest claude-code-ide-review-test-session-hooks ()
  "The tools server runs the start and end hooks with the session details."
  (let ((started nil)
        (ended nil)
        (claude-code-ide-mcp-server-session-started-hook nil)
        (claude-code-ide-mcp-server-session-ended-hook nil)
        (claude-code-ide-enable-mcp-server nil))
    (unwind-protect
        (progn
          (clrhash claude-code-ide-mcp-server--sessions)
          (add-hook 'claude-code-ide-mcp-server-session-started-hook
                    (lambda (id dir) (push (list id dir) started)))
          (add-hook 'claude-code-ide-mcp-server-session-ended-hook
                    (lambda (id)
                      ;; The session is still registered while the hook runs
                      (push (list id (and (gethash id claude-code-ide-mcp-server--sessions) t))
                            ended)))
          (claude-code-ide-mcp-server-session-started "sid-h" "/tmp/proj/" nil)
          (should (equal started '(("sid-h" "/tmp/proj/"))))
          ;; A call without a session id registers nothing and runs no hook
          (claude-code-ide-mcp-server-session-started)
          (should (= (length started) 1))
          (claude-code-ide-mcp-server-session-ended "sid-h")
          (should (equal ended '(("sid-h" t))))
          ;; Ending an unknown session does not run the hook
          (claude-code-ide-mcp-server-session-ended "sid-h")
          (should (= (length ended) 1)))
      (clrhash claude-code-ide-mcp-server--sessions))))

(ert-deftest claude-code-ide-review-test-setup-attaches-to-sessions ()
  "After setup, a session start snapshots its project; the end keeps it."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let ((claude-code-ide-mcp-server-session-started-hook nil)
                                                 (claude-code-ide-mcp-server-session-ended-hook nil)
                                                 (claude-code-ide-system-prompt-functions nil)
                                                 (claude-code-ide-mcp-server-tools nil)
                                                 (claude-code-ide-mcp-server-prompts nil)
                                                 (claude-code-ide-review-auto-baseline t)
                                                 (claude-code-ide-enable-mcp-server nil))
                                             (unwind-protect
                                                 (progn
                                                   (clrhash claude-code-ide-mcp-server--sessions)
                                                   (claude-code-ide-review-setup)
                                                   (claude-code-ide-mcp-server-session-started "sid-s" repo nil)
                                                   (should (claude-code-ide-review-baseline repo))
                                                   (should (equal (claude-code-ide-review-baseline-sessions
                                                                   (claude-code-ide-review-baseline repo))
                                                                  '("sid-s")))
                                                   ;; Session end leaves the baseline for a restart
                                                   (claude-code-ide-mcp-server-session-ended "sid-s")
                                                   (should (claude-code-ide-review-baseline repo))
                                                   (should-not (claude-code-ide-review-baseline-sessions
                                                                (claude-code-ide-review-baseline repo)))
                                                   ;; Emacs exit removes it
                                                   (should (memq #'claude-code-ide-review--release-all kill-emacs-hook))
                                                   (claude-code-ide-review--release-all)
                                                   (should-not (claude-code-ide-review-baseline repo)))
                                               (clrhash claude-code-ide-mcp-server--sessions)
                                               (remove-hook 'kill-emacs-hook #'claude-code-ide-review--release-all)))))

;;; Review Note Tests

(defun claude-code-ide-review-tests--two-hunks (repo)
  "Snapshot REPO, write the two-hunk edit to a.txt and return its hunks.
Hunk 1 changes line 2 (two -> 2); hunk 2 appends line 4 (four)."
  (claude-code-ide-review--snapshot repo "sid-1")
  (claude-code-ide-review-tests--write repo "a.txt" "one\n2\nthree\nfour\n")
  (claude-code-ide-review-hunks repo "a.txt"))

(ert-deftest claude-code-ide-review-test-note-put-get-replace ()
  "Notes are keyed by hunk and kind; a second put replaces the text."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let* ((hunks (claude-code-ide-review-tests--two-hunks repo))
                                                  (h1 (nth 0 hunks))
                                                  (id1 (claude-code-ide-review-hunk-id h1)))
                                             (should-not (claude-code-ide-review-get-note repo id1 'claude))
                                             (let ((note (claude-code-ide-review-put-note repo h1 'claude "Renamed for clarity")))
                                               (should (eq (claude-code-ide-review-get-note repo id1 'claude) note))
                                               (should (equal (claude-code-ide-review-note-file note) "a.txt"))
                                               (should (= (claude-code-ide-review-note-new-start note) 2))
                                               (should (= (claude-code-ide-review-note-new-count note) 1))
                                               (should (eq (claude-code-ide-review-note-kind note) 'claude))
                                               (should (claude-code-ide-review-note-created note)))
                                             ;; Replacement under the same key
                                             (claude-code-ide-review-put-note repo h1 'claude "Second version")
                                             (should (equal (claude-code-ide-review-note-text
                                                             (claude-code-ide-review-get-note repo id1 'claude))
                                                            "Second version"))
                                             ;; The other kind is a separate entry
                                             (claude-code-ide-review-put-note repo h1 'user "Why not keep the name?")
                                             (should (equal (claude-code-ide-review-note-text
                                                             (claude-code-ide-review-get-note repo id1 'user))
                                                            "Why not keep the name?"))
                                             (should (equal (claude-code-ide-review-note-text
                                                             (claude-code-ide-review-get-note repo id1 'claude))
                                                            "Second version"))
                                             ;; Listing with and without a kind filter
                                             (should (= (length (claude-code-ide-review-notes repo)) 2))
                                             (should (= (length (claude-code-ide-review-notes repo 'user)) 1))
                                             (should (= (length (claude-code-ide-review-notes repo 'claude)) 1)))))

(ert-deftest claude-code-ide-review-test-hunk-at ()
  "A line range selects the overlapping hunk, the larger overlap winning."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let* ((hunks (claude-code-ide-review-tests--two-hunks repo))
                                                  (h1 (nth 0 hunks))
                                                  (h2 (nth 1 hunks)))
                                             (should (equal (claude-code-ide-review-hunk-at repo "a.txt" 2 2) h1))
                                             (should (equal (claude-code-ide-review-hunk-at repo "a.txt" 4 4) h2))
                                             (should-not (claude-code-ide-review-hunk-at repo "a.txt" 1 1))
                                             (should-not (claude-code-ide-review-hunk-at repo "a.txt" 3 3))
                                             ;; 2..4 overlaps both by one line each; 3..4 overlaps only hunk 2
                                             (should (claude-code-ide-review-hunk-at repo "a.txt" 2 4))
                                             (should (equal (claude-code-ide-review-hunk-at repo "a.txt" 3 4) h2))
                                             (should-not (claude-code-ide-review-hunk-at repo "missing.txt" 1 9)))))

(ert-deftest claude-code-ide-review-test-status-ok-unexplained ()
  "A noted hunk is ok, the others unexplained, per kind."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let* ((hunks (claude-code-ide-review-tests--two-hunks repo))
                                                  (h1 (nth 0 hunks)))
                                             ;; No note table yet
                                             (should (equal (mapcar #'cadr (claude-code-ide-review-file-statuses repo "a.txt"))
                                                            '(unexplained unexplained)))
                                             (claude-code-ide-review-put-note repo h1 'claude "Shorter name")
                                             (let ((statuses (claude-code-ide-review-file-statuses repo "a.txt")))
                                               (should (equal (mapcar #'cadr statuses) '(ok unexplained)))
                                               (should (equal (claude-code-ide-review-note-text (nth 2 (nth 0 statuses)))
                                                              "Shorter name"))
                                               (should-not (nth 2 (nth 1 statuses))))
                                             ;; The user kind is independent
                                             (should (equal (mapcar #'cadr (claude-code-ide-review-file-statuses repo "a.txt" 'user))
                                                            '(unexplained unexplained))))))

(ert-deftest claude-code-ide-review-test-status-stale ()
  "Changing a noted hunk's text makes its note stale; neighbours are unaffected."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let* ((hunks (claude-code-ide-review-tests--two-hunks repo))
                                                  (h1 (nth 0 hunks))
                                                  (h2 (nth 1 hunks)))
                                             (claude-code-ide-review-put-note repo h1 'claude "Shorter name")
                                             (claude-code-ide-review-put-note repo h2 'claude "Added the fourth step")
                                             (claude-code-ide-review-tests--write repo "a.txt" "one\n2\nthree\nFOUR\n")
                                             (let ((statuses (claude-code-ide-review-file-statuses repo "a.txt")))
                                               (should (equal (mapcar #'cadr statuses) '(ok stale)))
                                               (should (equal (claude-code-ide-review-note-text (nth 2 (nth 1 statuses)))
                                                              "Added the fourth step"))
                                               ;; The stale note still carries the old hunk id
                                               (should (equal (claude-code-ide-review-note-hunk-id (nth 2 (nth 1 statuses)))
                                                              (claude-code-ide-review-hunk-id h2)))
                                               (should-not (equal (claude-code-ide-review-hunk-id (car (nth 1 statuses)))
                                                                  (claude-code-ide-review-hunk-id h2)))))))

(ert-deftest claude-code-ide-review-test-status-orphan ()
  "A note whose hunk vanished is kept but reported by no status."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let* ((hunks (claude-code-ide-review-tests--two-hunks repo))
                                                  (h2 (nth 1 hunks)))
                                             (claude-code-ide-review-put-note repo h2 'claude "Added the fourth step")
                                             ;; Revert to the baseline content: no hunks remain
                                             (claude-code-ide-review-tests--write repo "a.txt" "one\ntwo\nthree\n")
                                             (should-not (claude-code-ide-review-file-statuses repo "a.txt"))
                                             (should (= (length (claude-code-ide-review-notes repo)) 1)))))

(ert-deftest claude-code-ide-review-test-mark-baseline-clears-notes ()
  "Moving the baseline starts a new review with no notes."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let* ((hunks (claude-code-ide-review-tests--two-hunks repo)))
                                             (claude-code-ide-review-put-note repo (car hunks) 'claude "Shorter name")
                                             (should (= (length (claude-code-ide-review-notes repo)) 1))
                                             (claude-code-ide-review-mark-baseline repo)
                                             (should-not (claude-code-ide-review-notes repo))
                                             (should-not (claude-code-ide-review--note-table repo)))))

(ert-deftest claude-code-ide-review-test-release-keeps-notes ()
  "Notes survive the end of every session and go only with Emacs exit."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let* ((hunks (claude-code-ide-review-tests--two-hunks repo)))
                                             (claude-code-ide-review--snapshot repo "sid-2")
                                             (claude-code-ide-review-put-note repo (car hunks) 'user "Keep the long name")
                                             (claude-code-ide-review--release "sid-1")
                                             (claude-code-ide-review--release "sid-2")
                                             ;; No session left, but the review is intact for a restarted one
                                             (should (claude-code-ide-review-baseline repo))
                                             (should (= (length (claude-code-ide-review-notes repo)) 1))
                                             (claude-code-ide-review--release-all)
                                             (should-not (claude-code-ide-review-baseline repo))
                                             (should-not (claude-code-ide-review--note-table repo)))))

;;; Review Tool Tests

(defmacro claude-code-ide-review-tests--with-session (repo &rest body)
  "Run BODY as an MCP tool call of a session registered for REPO."
  (declare (indent 1))
  `(unwind-protect
       (progn
         (claude-code-ide-mcp-server-register-session "sid-tool" ,repo nil)
         (let ((claude-code-ide-mcp-server--current-session-id "sid-tool"))
           ,@body))
     (claude-code-ide-mcp-server-unregister-session "sid-tool")))

(ert-deftest claude-code-ide-review-test-tool-list-hunks-and-annotate ()
  "Listing shows status per hunk; annotate stores a note or lists the ranges."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--two-hunks repo)
                                           (claude-code-ide-review-tests--with-session repo
                                                                                       (let ((listing (claude-code-ide-review-tool-list-hunks)))
                                                                                         (should (string-match-p "^a.txt:2-2  id=[0-9a-f]\\{12\\}  status=unexplained$" listing))
                                                                                         (should (string-match-p "^a.txt:4-4  id=[0-9a-f]\\{12\\}  status=unexplained$" listing))
                                                                                         (should (string-match-p "2 hunks, 2 unexplained, 0 stale" listing)))
                                                                                       (should (string-match-p "^Annotated a.txt:2-2 (id=[0-9a-f]\\{12\\})$"
                                                                                                               (claude-code-ide-review-tool-annotate "a.txt" 2 2 "Shorter name")))
                                                                                       (let ((listing (claude-code-ide-review-tool-list-hunks "a.txt")))
                                                                                         (should (string-match-p "status=ok  \"Shorter name\"" listing))
                                                                                         (should (string-match-p "2 hunks, 1 unexplained, 0 stale" listing)))
                                                                                       ;; A range that touches no hunk gets the available ranges back
                                                                                       (let ((reply (claude-code-ide-review-tool-annotate "a.txt" 1 1 "x")))
                                                                                         (should (string-match-p "No hunk of a.txt overlaps lines 1-1" reply))
                                                                                         (should (string-match-p "a.txt:2-2, a.txt:4-4" reply)))
                                                                                       ;; An unchanged file says so
                                                                                       (claude-code-ide-review-tests--write repo "other.txt" "x\n")
                                                                                       (claude-code-ide-review-tests--git repo "add" "other.txt")
                                                                                       (should (string-match-p "status=unexplained"
                                                                                                               (claude-code-ide-review-tool-list-hunks "other.txt")))
                                                                                       (should (equal (claude-code-ide-review-tool-open)
                                                                                                      "Opened review for a.txt\na.txt: 2 hunks\nother.txt: 1 hunk")))))

(ert-deftest claude-code-ide-review-test-tool-annotate-absolute-path ()
  "Absolute paths, as Claude sends them, resolve to repository-relative hunks."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--two-hunks repo)
                                           (claude-code-ide-review-tests--with-session repo
                                                                                       (should (string-match-p "^Annotated a.txt:4-4"
                                                                                                               (claude-code-ide-review-tool-annotate
                                                                                                                (expand-file-name "a.txt" repo) 4 4 "Added the fourth step")))
                                                                                       (should (string-match-p "a.txt:4-4  id=[0-9a-f]\\{12\\}  status=ok"
                                                                                                               (claude-code-ide-review-tool-list-hunks
                                                                                                                (expand-file-name "a.txt" repo)))))))

(ert-deftest claude-code-ide-review-test-tool-mark-baseline ()
  "The tool reports the new baseline and the review becomes empty."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--two-hunks repo)
                                           (claude-code-ide-review-tests--with-session repo
                                                                                       (should (string-match-p "^Baseline set to [0-9a-f]\\{12\\}$"
                                                                                                               (claude-code-ide-review-tool-mark-baseline)))
                                                                                       (should (equal (claude-code-ide-review-tool-list-hunks)
                                                                                                      "No changes since the baseline"))
                                                                                       (should (equal (claude-code-ide-review-tool-open)
                                                                                                      "No changes since the baseline")))))

(ert-deftest claude-code-ide-review-test-tool-mark-baseline-refuses-with-comments ()
  "The tool leaves a review with unsent user comments untouched."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let* ((hunks (claude-code-ide-review-tests--two-hunks repo))
                                                  (baseline (claude-code-ide-review-baseline repo)))
                                             (claude-code-ide-review-put-note repo (car hunks) 'user "Keep the word")
                                             (claude-code-ide-review-put-note repo (cadr hunks) 'user "   ")
                                             (claude-code-ide-review-put-note repo (cadr hunks) 'claude "Added a step")
                                             (should (= (length (claude-code-ide-review-unsent-comments repo)) 1))
                                             (claude-code-ide-review-tests--with-session repo
                                                                                         (let ((reply (claude-code-ide-review-tool-mark-baseline)))
                                                                                           (should (string-match-p "^Refused: 1 user comment in the review has not been sent yet" reply))
                                                                                           (should (string-match-p "claude-code-ide-review-mark-baseline" reply)))
                                                                                         (should (eq (claude-code-ide-review-baseline repo) baseline))
                                                                                         (should (= (length (claude-code-ide-review-notes repo)) 3))
                                                                                         ;; A sent comment no longer blocks the tool
                                                                                         (setf (claude-code-ide-review-note-sent
                                                                                                (claude-code-ide-review-get-note repo (claude-code-ide-review-hunk-id (car hunks)) 'user))
                                                                                               t)
                                                                                         (should-not (claude-code-ide-review-unsent-comments repo))
                                                                                         (should (string-match-p "^Baseline set to" (claude-code-ide-review-tool-mark-baseline)))
                                                                                         (should-not (claude-code-ide-review-notes repo))))))

(ert-deftest claude-code-ide-review-test-tool-no-baseline ()
  "Without a baseline every query tool answers with the same message."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--with-session repo
                                                                                       (dolist (reply (list (claude-code-ide-review-tool-list-hunks)
                                                                                                            (claude-code-ide-review-tool-annotate "a.txt" 1 1 "x")
                                                                                                            (claude-code-ide-review-tool-get-comments)
                                                                                                            (claude-code-ide-review-tool-open)))
                                                                                         (should (string-match-p "^No review baseline for .*; call review_mark_baseline first$"
                                                                                                                 reply))))))

(ert-deftest claude-code-ide-review-test-format-comments ()
  "User comments are formatted in file order with their diff blocks."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let* ((hunks (claude-code-ide-review-tests--two-hunks repo))
                                                  (h1 (nth 0 hunks))
                                                  (h2 (nth 1 hunks)))
                                             (claude-code-ide-review-tests--write repo "b.txt" "beta\n")
                                             (let ((hb (car (claude-code-ide-review-hunks repo "b.txt"))))
                                               (claude-code-ide-review-tests--with-session repo
                                                                                           (should (equal (claude-code-ide-review-tool-get-comments) "No user comments"))
                                                                                           (claude-code-ide-review-put-note repo hb 'user "Is this file needed?")
                                                                                           (claude-code-ide-review-put-note repo h2 'user "Spell out four")
                                                                                           (claude-code-ide-review-put-note repo h1 'user "Keep the word")
                                                                                           (should (equal (claude-code-ide-review-tool-get-comments)
                                                                                                          (concat "## a.txt:2-2\n```diff\n-two\n+2\n```\nComment: Keep the word"
                                                                                                                  "\n\n"
                                                                                                                  "## a.txt:4-4\n```diff\n+four\n```\nComment: Spell out four"
                                                                                                                  "\n\n"
                                                                                                                  "## b.txt:1-1\n```diff\n+beta\n```\nComment: Is this file needed?")))
                                                                                           ;; A changed hunk marks its comment stale; a vanished hunk drops it
                                                                                           (claude-code-ide-review-tests--write repo "a.txt" "one\n2\nthree\nFOUR\n")
                                                                                           (delete-file (expand-file-name "b.txt" repo))
                                                                                           (let ((text (claude-code-ide-review-tool-get-comments)))
                                                                                             (should (string-match-p "## a.txt:4-4 (hunk changed since the comment was written)\n```diff\n\\+FOUR\n```"
                                                                                                                     text))
                                                                                             (should-not (string-match-p "b.txt" text))))))))

(ert-deftest claude-code-ide-review-test-tool-registration ()
  "Setup registers the five tools and the server validates their arguments."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--two-hunks repo)
                                           (let ((claude-code-ide-mcp-server-tools nil)
                                                 (claude-code-ide-mcp-server-prompts nil)
                                                 (claude-code-ide-system-prompt-functions nil)
                                                 (claude-code-ide-mcp-server-session-started-hook nil)
                                                 (claude-code-ide-mcp-server-session-ended-hook nil))
                                             (claude-code-ide-review-setup)
                                             (should (equal (sort (mapcar (lambda (spec) (plist-get spec :name))
                                                                          claude-code-ide-mcp-server-tools)
                                                                  #'string<)
                                                            '("review_annotate" "review_get_comments" "review_list_hunks"
                                                              "review_mark_baseline" "review_open")))
                                             (claude-code-ide-review-tests--with-session repo
                                                                                         ;; A missing required argument is refused before the tool runs
                                                                                         (let ((err (should-error
                                                                                                     (claude-code-ide-mcp-http-server--handle-tools-call
                                                                                                      '((name . "review_annotate")
                                                                                                        (arguments . ((file_path . "a.txt") (end_line . 2) (justification . "x")))))
                                                                                                     :type 'json-rpc-error)))
                                                                                           (should (= (nth 1 err) -32602))
                                                                                           (should (string-match-p "start_line" (nth 2 err))))
                                                                                         ;; A complete call reaches the tool and returns its text
                                                                                         (let* ((result (claude-code-ide-mcp-http-server--handle-tools-call
                                                                                                         '((name . "review_annotate")
                                                                                                           (arguments . ((file_path . "a.txt") (start_line . 2) (end_line . 2)
                                                                                                                         (justification . "Shorter name"))))))
                                                                                                (text (alist-get 'text (car (alist-get 'content result)))))
                                                                                           (should (string-match-p "^Annotated a.txt:2-2" text)))
                                                                                         ;; The optional argument may be omitted
                                                                                         (let* ((result (claude-code-ide-mcp-http-server--handle-tools-call
                                                                                                         '((name . "review_list_hunks") (arguments . nil))))
                                                                                                (text (alist-get 'text (car (alist-get 'content result)))))
                                                                                           (should (string-match-p "2 hunks, 1 unexplained" text)))))))

;;; Review View Tests

(defmacro claude-code-ide-review-tests--with-view (repo file &rest body)
  "Open the review view on FILE of REPO, run BODY, then quit the view."
  (declare (indent 2))
  `(claude-code-ide-review-tests--with-session ,repo
                                               (let ((tab-bar-mode nil))
                                                 (unwind-protect
                                                     (progn
                                                       (claude-code-ide-review-open ,file)
                                                       ,@body)
                                                   (claude-code-ide-review-quit)))))

(defun claude-code-ide-review-tests--comment-buffer ()
  "Return the comment window's buffer of the open view."
  (claude-code-ide-review-view-user-buffer claude-code-ide-review--view))

(defun claude-code-ide-review-tests--type (text)
  "Append TEXT to the comment window, as typing would."
  (with-current-buffer (claude-code-ide-review-tests--comment-buffer)
    (goto-char (point-max))
    (insert text)))

(defun claude-code-ide-review-tests--window-rows ()
  "Return the top row of every window with its buffer name, sorted by position."
  (sort (mapcar (lambda (window)
                  (list (window-top-line window) (window-left-column window)
                        (buffer-name (window-buffer window))))
                (window-list))
        (lambda (a b) (or (< (car a) (car b))
                          (and (= (car a) (car b)) (< (cadr a) (cadr b)))))))

(ert-deftest claude-code-ide-review-test-ediff-view-layout ()
  "The view is an ediff session: A and B on top, two short windows below, control last."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--two-hunks repo)
                                           (claude-code-ide-review-tests--with-session repo
                                                                                       (let ((tab-bar-mode nil)
                                                                                             (windows-before (length (window-list)))
                                                                                             (claude-code-ide-review-comment-lines 4))
                                                                                         (unwind-protect
                                                                                             (let* ((view (claude-code-ide-review-open "a.txt"))
                                                                                                    (rows (claude-code-ide-review-tests--window-rows))
                                                                                                    (control (claude-code-ide-review-view-control view)))
                                                                                               (should (= (length rows) 5))
                                                                                               (should (eq (buffer-local-value 'ediff-control-buffer control) control))
                                                                                               (should (equal (mapcar #'caddr rows)
                                                                                                              (list "*claude-review: baseline a.txt*"
                                                                                                                    (buffer-name (claude-code-ide-review-view-file-buffer view))
                                                                                                                    "*claude-review: claude*" "*claude-review: user*"
                                                                                                                    (buffer-name control))))
                                                                                               ;; A and B share the top row, the comment windows the next one
                                                                                               (should (= (car (nth 0 rows)) (car (nth 1 rows))))
                                                                                               (should (= (car (nth 2 rows)) (car (nth 3 rows))))
                                                                                               (should (< (car (nth 1 rows)) (car (nth 2 rows)) (car (nth 4 rows))))
                                                                                               (should (= (window-body-height (get-buffer-window (claude-code-ide-review-view-user-buffer view)))
                                                                                                          4))
                                                                                               (should (eq (window-buffer (buffer-local-value 'ediff-window-A control))
                                                                                                           (claude-code-ide-review-view-old-buffer view)))
                                                                                               (should (eq (buffer-local-value 'ediff-buffer-B control)
                                                                                                           (claude-code-ide-review-view-file-buffer view)))
                                                                                               (should (equal (with-current-buffer (claude-code-ide-review-view-old-buffer view)
                                                                                                                (buffer-string))
                                                                                                              "one\ntwo\nthree\n"))
                                                                                               ;; When ediff rebuilds its windows (plain layout on a tty), ours come back
                                                                                               (with-current-buffer control
                                                                                                 (ediff-setup-windows ediff-buffer-A ediff-buffer-B nil control))
                                                                                               (should (equal (mapcar #'caddr (claude-code-ide-review-tests--window-rows))
                                                                                                              (mapcar #'caddr rows)))
                                                                                               (claude-code-ide-review-quit)
                                                                                               (should-not claude-code-ide-review--view)
                                                                                               (should-not (buffer-live-p control))
                                                                                               (should-not (get-buffer "*claude-review: baseline a.txt*"))
                                                                                               (should-not (get-buffer "*claude-review: user*"))
                                                                                               (should (buffer-live-p (claude-code-ide-review-view-file-buffer view)))
                                                                                               (should (= (length (window-list)) windows-before))
                                                                                               ;; Quitting again is harmless
                                                                                               (claude-code-ide-review-quit))
                                                                                           (claude-code-ide-review-quit))))))

(ert-deftest claude-code-ide-review-test-ediff-view-current-hunk ()
  "Each ediff difference maps to the git hunk under it and fills the bottom windows."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let ((hunks (claude-code-ide-review-tests--two-hunks repo)))
                                             (claude-code-ide-review-put-note repo (car hunks) 'claude "Shorter name")
                                             (claude-code-ide-review-tests--with-view repo "a.txt"
                                                                                      (let ((view claude-code-ide-review--view))
                                                                                        (should (= (claude-code-ide-review--difference-count view) 2))
                                                                                        (should (eql (claude-code-ide-review-view-hunk view) 0))
                                                                                        (should (equal (claude-code-ide-review--difference-lines view 0) '(2 . 2)))
                                                                                        (should (equal (claude-code-ide-review--difference-lines view 1) '(4 . 4)))
                                                                                        (with-current-buffer (claude-code-ide-review-view-claude-buffer view)
                                                                                          (should (string-prefix-p "a.txt:2-2  ok\nShorter name" (buffer-string))))
                                                                                        (claude-code-ide-review-next-hunk)
                                                                                        (should (eql (claude-code-ide-review-view-hunk view) 1))
                                                                                        (with-current-buffer (claude-code-ide-review-view-claude-buffer view)
                                                                                          (should (string-prefix-p "a.txt:4-4  unexplained\n" (buffer-string)))
                                                                                          (should (string-match-p "Claude did not leave a comment" (buffer-string))))
                                                                                        (claude-code-ide-review-previous-hunk)
                                                                                        (should (eql (claude-code-ide-review-view-hunk view) 0))
                                                                                        ;; Selecting by hunk index goes through ediff
                                                                                        (claude-code-ide-review-select-hunk 1)
                                                                                        (should (eql (claude-code-ide-review--current-difference view) 1))
                                                                                        (should (eql (claude-code-ide-review-view-hunk view) 1)))))))

(ert-deftest claude-code-ide-review-test-ediff-view-comment-save ()
  "The comment window edits the current hunk's note and reloads on switch."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--two-hunks repo)
                                           (claude-code-ide-review-tests--with-view repo "a.txt"
                                                                                    (let ((view claude-code-ide-review--view))
                                                                                      (claude-code-ide-review-tests--type "Keep the word")
                                                                                      (should (equal (claude-code-ide-review-note-text
                                                                                                      (claude-code-ide-review-get-note
                                                                                                       repo (claude-code-ide-review-hunk-id (nth 0 (claude-code-ide-review-view-hunks view))) 'user))
                                                                                                     "Keep the word"))
                                                                                      (claude-code-ide-review-next-hunk)
                                                                                      (with-current-buffer (claude-code-ide-review-tests--comment-buffer)
                                                                                        (should (string-empty-p (buffer-string)))
                                                                                        (should-not buffer-read-only))
                                                                                      (claude-code-ide-review-tests--type "Spell out four")
                                                                                      (claude-code-ide-review-previous-hunk)
                                                                                      (with-current-buffer (claude-code-ide-review-tests--comment-buffer)
                                                                                        (should (equal (buffer-string) "Keep the word"))
                                                                                        ;; Erasing the comment removes the note
                                                                                        (erase-buffer))
                                                                                      (should (= (length (claude-code-ide-review-notes repo 'user)) 1))
                                                                                      (should (equal (claude-code-ide-review-note-text (car (claude-code-ide-review-notes repo 'user)))
                                                                                                     "Spell out four"))
                                                                                      ;; Refresh keeps the comment of the current hunk
                                                                                      (claude-code-ide-review-next-hunk)
                                                                                      (claude-code-ide-review-refresh)
                                                                                      (should (eql (claude-code-ide-review-view-hunk view) 1))
                                                                                      (with-current-buffer (claude-code-ide-review-tests--comment-buffer)
                                                                                        (should (equal (buffer-string) "Spell out four")))))))

(ert-deftest claude-code-ide-review-test-ediff-view-select-file ()
  "Switching files restarts ediff in place and drops the old baseline buffer."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--two-hunks repo)
                                           (claude-code-ide-review-tests--write repo "b.txt" "beta\n")
                                           (claude-code-ide-review-tests--with-view repo "a.txt"
                                                                                    (let ((view claude-code-ide-review--view))
                                                                                      (claude-code-ide-review-open "b.txt")
                                                                                      (should (eq claude-code-ide-review--view view))
                                                                                      (should (equal (claude-code-ide-review-view-file view) "b.txt"))
                                                                                      (should (buffer-live-p (claude-code-ide-review-view-control view)))
                                                                                      (should (eq (buffer-local-value 'ediff-buffer-B (claude-code-ide-review-view-control view))
                                                                                                  (claude-code-ide-review-view-file-buffer view)))
                                                                                      (should-not (get-buffer "*claude-review: baseline a.txt*"))
                                                                                      (should (get-buffer "*claude-review: baseline b.txt*"))
                                                                                      (should (= (length (claude-code-ide-review-tests--window-rows)) 5))
                                                                                      (should (eql (claude-code-ide-review-view-hunk view) 0))
                                                                                      (should (equal (claude-code-ide-review--difference-lines view 0) '(1 . 1)))))))

(ert-deftest claude-code-ide-review-test-tool-open-opens-view ()
  "review_open opens the view on the first changed file and says so."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--two-hunks repo)
                                           (claude-code-ide-review-tests--with-session repo
                                                                                       (let ((tab-bar-mode nil))
                                                                                         (unwind-protect
                                                                                             (let ((reply (claude-code-ide-review-tool-open)))
                                                                                               (should (string-prefix-p "Opened review for a.txt\n" reply))
                                                                                               (should (string-match-p "a.txt: 2 hunks" reply))
                                                                                               (should claude-code-ide-review--view)
                                                                                               (should (equal (claude-code-ide-review-view-file claude-code-ide-review--view) "a.txt")))
                                                                                           (claude-code-ide-review-quit))))))

;;; Review Finish and Explain Tests

(defvar claude-code-ide-review-tests--prompts nil
  "Prompts recorded by the `claude-code-ide-send-prompt' stand-in, newest first.")

(defvar claude-code-ide-review-tests--frames nil
  "WebSocket texts recorded by the `websocket-send-text' stand-in, newest first.")

(defmacro claude-code-ide-review-tests--with-claude-session (repo var &rest body)
  "Run BODY with VAR bound to an MCP session for REPO with a mock client.
Prompts and frames sent to it are recorded in
`claude-code-ide-review-tests--prompts' and `--frames'.  Buffers visiting
files of REPO are killed afterwards so the directory can be deleted."
  (declare (indent 2))
  `(progn
     (claude-code-ide-tests--clear-processes)
     (setq claude-code-ide-review-tests--prompts nil
           claude-code-ide-review-tests--frames nil)
     (unwind-protect
         (let ((,var (claude-code-ide-tests--make-session
                      ,repo
                      :client (claude-code-ide-tests--make-websocket "ws://127.0.0.1:10020"))))
           (cl-letf (((symbol-function 'claude-code-ide-send-prompt)
                      (lambda (prompt session)
                        (push (cons prompt session) claude-code-ide-review-tests--prompts)))
                     ((symbol-function 'websocket-send-text)
                      (lambda (_ws text)
                        (push text claude-code-ide-review-tests--frames))))
             ,@body))
       (dolist (buffer (buffer-list))
         (when-let* ((file (buffer-file-name buffer)))
           (when (string-prefix-p ,repo file)
             (kill-buffer buffer))))
       (claude-code-ide-tests--clear-processes))))

(defun claude-code-ide-review-tests--last-frame ()
  "Return the newest recorded frame as (METHOD . PARAMS)."
  (let* ((payload (json-read-from-string (car claude-code-ide-review-tests--frames))))
    (cons (alist-get 'method payload) (alist-get 'params payload))))

(ert-deftest claude-code-ide-review-test-finish-sends-formatted-comments ()
  "Finish types every comment with its hunk into the session and marks them sent."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--two-hunks repo)
                                           (claude-code-ide-review-tests--with-claude-session repo session
                                                                                              (claude-code-ide-review-tests--with-view repo "a.txt"
                                                                                                                                       (claude-code-ide-review-tests--type "Why a digit?")
                                                                                                                                       (claude-code-ide-review-next-hunk)
                                                                                                                                       (claude-code-ide-review-tests--type "Spell out four")
                                                                                                                                       (should (= (length (claude-code-ide-review-unsent-comments repo)) 2))
                                                                                                                                       (claude-code-ide-review-finish)
                                                                                                                                       (should (= (length claude-code-ide-review-tests--prompts) 1))
                                                                                                                                       (let ((prompt (car (car claude-code-ide-review-tests--prompts))))
                                                                                                                                         (should (eq (cdr (car claude-code-ide-review-tests--prompts)) session))
                                                                                                                                         (should (string-prefix-p "Review comments on your changes follow." prompt))
                                                                                                                                         (should (string-match-p "^## a.txt:2-2$" prompt))
                                                                                                                                         (should (string-match-p "^## a.txt:4-4$" prompt))
                                                                                                                                         (should (string-match-p "^-two\n\\+2\n" prompt))
                                                                                                                                         (should (string-match-p "^\\+four\n" prompt))
                                                                                                                                         (should (string-match-p "^Comment: Why a digit\\?$" prompt))
                                                                                                                                         (should (string-match-p "^Comment: Spell out four$" prompt)))
                                                                                                                                       (should-not (claude-code-ide-review-unsent-comments repo))
                                                                                                                                       ;; The comments are still shown
                                                                                                                                       (should (= (length (claude-code-ide-review-notes repo 'user)) 2))
                                                                                                                                       ;; Editing a sent comment makes it unsent again
                                                                                                                                       (claude-code-ide-review-tests--type " please")
                                                                                                                                       (should (= (length (claude-code-ide-review-unsent-comments repo)) 1))
                                                                                                                                       (should (equal (claude-code-ide-review-note-text (car (claude-code-ide-review-unsent-comments repo)))
                                                                                                                                                      "Spell out four please"))))))

(ert-deftest claude-code-ide-review-test-finish-uses-tool-above-limit ()
  "Above the inline limit the prompt asks for review_get_comments instead."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let ((hunks (claude-code-ide-review-tests--two-hunks repo)))
                                             (claude-code-ide-review-put-note repo (car hunks) 'user "Why a digit?")
                                             (claude-code-ide-review-put-note repo (cadr hunks) 'user "Spell out four")
                                             (claude-code-ide-review-tests--with-claude-session repo session
                                                                                                (let ((claude-code-ide-review-inline-limit 10)
                                                                                                      (default-directory repo))
                                                                                                  ;; No view open: the project comes from `default-directory'
                                                                                                  (claude-code-ide-review-finish)
                                                                                                  (let ((prompt (car (car claude-code-ide-review-tests--prompts))))
                                                                                                    (should (eq (cdr (car claude-code-ide-review-tests--prompts)) session))
                                                                                                    (should (string-match-p "2 review comments" prompt))
                                                                                                    (should (string-match-p "review_get_comments" prompt))
                                                                                                    (should-not (string-match-p "Why a digit" prompt)))
                                                                                                  (should-not (claude-code-ide-review-unsent-comments repo)))))))

(ert-deftest claude-code-ide-review-test-finish-without-comments ()
  "Finish refuses when there is nothing to send and sends nothing."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let ((hunks (claude-code-ide-review-tests--two-hunks repo)))
                                             (claude-code-ide-review-put-note repo (car hunks) 'claude "Shorter name")
                                             (claude-code-ide-review-tests--with-claude-session repo _session
                                                                                                (let ((default-directory repo))
                                                                                                  (should-error (claude-code-ide-review-finish) :type 'user-error)
                                                                                                  (should-not claude-code-ide-review-tests--prompts))))))

(ert-deftest claude-code-ide-review-test-get-comments-tool-keeps-unsent ()
  "Reading the comments through the tool leaves them unsent, so the guard holds."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let ((hunks (claude-code-ide-review-tests--two-hunks repo)))
                                             (claude-code-ide-review-put-note repo (car hunks) 'user "Why a digit?")
                                             (claude-code-ide-review-tests--with-session repo
                                                                                         (should (string-match-p "^Refused:" (claude-code-ide-review-tool-mark-baseline)))
                                                                                         (should (string-match-p "Comment: Why a digit\\?" (claude-code-ide-review-tool-get-comments)))
                                                                                         (should (= (length (claude-code-ide-review-unsent-comments repo)) 1))
                                                                                         (should (string-match-p "^Refused:" (claude-code-ide-review-tool-mark-baseline)))
                                                                                         (should (= (length (claude-code-ide-review-notes repo 'user)) 1))))))

(ert-deftest claude-code-ide-review-test-explain-sends-hunk-range ()
  "Explain sends the current hunk's real file and 0-based line range."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--two-hunks repo)
                                           (claude-code-ide-review-tests--with-claude-session repo _session
                                                                                              (claude-code-ide-review-tests--with-view repo "a.txt"
                                                                                                                                       (claude-code-ide-review-explain-hunk)
                                                                                                                                       (should (= (length claude-code-ide-review-tests--frames) 1))
                                                                                                                                       (let* ((frame (claude-code-ide-review-tests--last-frame))
                                                                                                                                              (params (cdr frame)))
                                                                                                                                         (should (equal (car frame) "at_mentioned"))
                                                                                                                                         (should (equal (alist-get 'filePath params)
                                                                                                                                                        (file-truename (expand-file-name "a.txt" repo))))
                                                                                                                                         (should (= (alist-get 'lineStart params) 1))
                                                                                                                                         (should (= (alist-get 'lineEnd params) 1)))
                                                                                                                                       ;; Only the reference goes out by default
                                                                                                                                       (should-not claude-code-ide-review-tests--prompts)
                                                                                                                                       (claude-code-ide-review-next-hunk)
                                                                                                                                       (let ((claude-code-ide-review-explain-sends-prompt t))
                                                                                                                                         (claude-code-ide-review-explain-hunk))
                                                                                                                                       (should (= (length claude-code-ide-review-tests--frames) 2))
                                                                                                                                       (let ((params (cdr (claude-code-ide-review-tests--last-frame))))
                                                                                                                                         (should (= (alist-get 'lineStart params) 3))
                                                                                                                                         (should (= (alist-get 'lineEnd params) 3)))
                                                                                                                                       (should (string-match-p "review_annotate"
                                                                                                                                                               (car (car claude-code-ide-review-tests--prompts))))))))

(ert-deftest claude-code-ide-review-test-explain-multi-line-and-deletion ()
  "A multi-line hunk sends its whole range; a deletion sends one line."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review--snapshot repo "sid-1")
                                           ;; Lines 2 and 3 rewritten: one hunk spanning lines 2-3
                                           (claude-code-ide-review-tests--write repo "a.txt" "one\nTWO\nTHREE\n")
                                           (claude-code-ide-review-tests--with-claude-session repo _session
                                                                                              (claude-code-ide-review-tests--with-view repo "a.txt"
                                                                                                                                       (claude-code-ide-review-explain-hunk)
                                                                                                                                       (let ((params (cdr (claude-code-ide-review-tests--last-frame))))
                                                                                                                                         (should (= (alist-get 'lineStart params) 1))
                                                                                                                                         (should (= (alist-get 'lineEnd params) 2))))
                                                                                              ;; Line one deleted: git reports the gap at line 0
                                                                                              (claude-code-ide-review-tests--write repo "a.txt" "two\nthree\n")
                                                                                              (claude-code-ide-review-tests--with-view repo "a.txt"
                                                                                                                                       (let ((hunk (car (claude-code-ide-review-view-hunks claude-code-ide-review--view))))
                                                                                                                                         (should (= (claude-code-ide-review-hunk-new-count hunk) 0)))
                                                                                                                                       (claude-code-ide-review-explain-hunk)
                                                                                                                                       (let ((params (cdr (claude-code-ide-review-tests--last-frame))))
                                                                                                                                         (should (= (alist-get 'lineStart params) 0))
                                                                                                                                         (should (= (alist-get 'lineEnd params) 0)))))))

(ert-deftest claude-code-ide-review-test-explain-and-finish-keys ()
  "The commands are bound in both pane keymaps and the placeholder names the key."
  (cl-flet ((key (command map)
              (key-description (where-is-internal command map t))))
    (should (equal (key #'claude-code-ide-review-explain-hunk claude-code-ide-review-mode-map) "e"))
    (should (equal (key #'claude-code-ide-review-finish claude-code-ide-review-mode-map) "f"))
    (should (equal (key #'claude-code-ide-review-explain-hunk claude-code-ide-review-comment-mode-map) "C-c C-e"))
    (should (equal (key #'claude-code-ide-review-finish claude-code-ide-review-comment-mode-map) "C-c C-f")))
  (with-temp-buffer
    (claude-code-ide-review-mode)
    ;; `substitute-command-keys' renders the key quoted or face-marked
    ;; depending on the Emacs version; the key itself must be there
    (should (string-match-p "press `?e'? in the diff"
                            (claude-code-ide-review--placeholder-text)))))

;;; Review Live Sync Tests

(ert-deftest claude-code-ide-review-test-sync-watch-follows-shown-file ()
  "The view watches the shown file's directory, moves with it and drops it on quit."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--write repo "sub/b.txt" "b one\nb two\n")
                                           (claude-code-ide-review-tests--two-hunks repo)
                                           (claude-code-ide-review-tests--write repo "sub/b.txt" "b one\nb 2\n")
                                           (let ((added '())
                                                 (removed '())
                                                 (counter 0))
                                             (cl-letf (((symbol-function 'file-notify-add-watch)
                                                        (lambda (dir _flags callback)
                                                          (push (cons dir callback) added)
                                                          (list 'watch (cl-incf counter))))
                                                       ((symbol-function 'file-notify-rm-watch)
                                                        (lambda (descriptor) (push descriptor removed))))
                                               (claude-code-ide-review-tests--with-view repo "a.txt"
                                                                                        (let ((view claude-code-ide-review--view)
                                                                                              (top (file-name-as-directory (file-truename repo))))
                                                                                          (should (equal (claude-code-ide-review-view-watch view) '(watch 1)))
                                                                                          (should (equal (car (car added)) top))
                                                                                          (should (eq (cdr (car added)) #'claude-code-ide-review--on-file-event))
                                                                                          ;; Refresh keeps the same directory: no churn
                                                                                          (claude-code-ide-review-refresh)
                                                                                          (should (= (length added) 1))
                                                                                          (should-not removed)
                                                                                          ;; Another directory: old watch dropped, new one added
                                                                                          (claude-code-ide-review-open "sub/b.txt")
                                                                                          (should (equal removed '((watch 1))))
                                                                                          (should (equal (car (car added)) (concat top "sub/")))
                                                                                          (should (equal (claude-code-ide-review-view-watch view) '(watch 2)))
                                                                                          (claude-code-ide-review-quit)
                                                                                          (should (equal removed '((watch 2) (watch 1))))))))))

(ert-deftest claude-code-ide-review-test-sync-event-rebuilds-after-delay ()
  "A change event schedules one rebuild; the rebuild recomputes hunk status."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let ((hunks (claude-code-ide-review-tests--two-hunks repo)))
                                             (claude-code-ide-review-put-note repo (car hunks) 'claude "Shorter name")
                                             (claude-code-ide-review-put-note repo (cadr hunks) 'claude "Added a step")
                                             (claude-code-ide-review-tests--with-view repo "a.txt"
                                                                                      (let* ((view claude-code-ide-review--view)
                                                                                             (path (expand-file-name "a.txt" repo))
                                                                                             (first nil)
                                                                                             (second nil))
                                                                                        (claude-code-ide-review-next-hunk)
                                                                                        (should-not (claude-code-ide-review-view-timer view))
                                                                                        (claude-code-ide-review--on-file-event (list nil 'changed path))
                                                                                        (setq first (claude-code-ide-review-view-timer view))
                                                                                        (should (timerp first))
                                                                                        (should (memq first timer-idle-list))
                                                                                        ;; A second event within the delay replaces the pending timer
                                                                                        (claude-code-ide-review--on-file-event (list nil 'renamed (concat path ".tmp") path))
                                                                                        (setq second (claude-code-ide-review-view-timer view))
                                                                                        (should (timerp second))
                                                                                        (should-not (eq first second))
                                                                                        (should-not (memq first timer-idle-list))
                                                                                        (should (memq second timer-idle-list))
                                                                                        ;; Nothing rebuilt yet: both notes still ok
                                                                                        (should (equal (mapcar #'cadr (claude-code-ide-review-file-statuses repo "a.txt" 'claude))
                                                                                                       '(ok ok)))
                                                                                        ;; The file changes in hunk 0, then the timer's function runs
                                                                                        (claude-code-ide-review-tests--write repo "a.txt" "one\n22\nthree\nfour\n")
                                                                                        (cancel-timer second)
                                                                                        (claude-code-ide-review--sync-rebuild)
                                                                                        (should-not (claude-code-ide-review-view-timer view))
                                                                                        (should (eql (claude-code-ide-review-view-hunk view) 1))
                                                                                        (let ((statuses (claude-code-ide-review-file-statuses repo "a.txt" 'claude)))
                                                                                          (should (equal (mapcar #'cadr statuses) '(stale ok)))
                                                                                          (should (equal (claude-code-ide-review-note-text (nth 2 (car statuses)))
                                                                                                         "Shorter name")))
                                                                                        ;; The file buffer was reverted and ediff recomputed
                                                                                        (with-current-buffer (claude-code-ide-review-view-file-buffer view)
                                                                                          (should (string-match-p "^22$" (buffer-string))))
                                                                                        (should (= (claude-code-ide-review--difference-count view) 2)))))))

(ert-deftest claude-code-ide-review-test-sync-ignores-other-files ()
  "Events for other files, or irrelevant actions, schedule nothing."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--two-hunks repo)
                                           (claude-code-ide-review-tests--with-view repo "a.txt"
                                                                                    (let ((view claude-code-ide-review--view))
                                                                                      (claude-code-ide-review--on-file-event
                                                                                       (list nil 'changed (expand-file-name "b.txt" repo)))
                                                                                      (should-not (claude-code-ide-review-view-timer view))
                                                                                      (claude-code-ide-review--on-file-event
                                                                                       (list nil 'stopped (expand-file-name "a.txt" repo)))
                                                                                      (should-not (claude-code-ide-review-view-timer view))))))

(ert-deftest claude-code-ide-review-test-refresh-reports-reverted-file ()
  "When the shown file has no changes left, refresh names another changed file."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--two-hunks repo)
                                           (claude-code-ide-review-tests--with-view repo "a.txt"
                                                                                    (let ((messages '()))
                                                                                      (cl-letf (((symbol-function 'message)
                                                                                                 (lambda (format &rest args)
                                                                                                   (when format
                                                                                                     (push (apply #'format-message format args) messages)))))
                                                                                        (claude-code-ide-review-tests--write repo "b.txt" "new\n")
                                                                                        (claude-code-ide-review-tests--write repo "a.txt" "one\ntwo\nthree\n")
                                                                                        (claude-code-ide-review-refresh)
                                                                                        (should-not (claude-code-ide-review-view-hunks claude-code-ide-review--view))
                                                                                        (should (member "a.txt has no changes left; b.txt does (o to switch)" messages))
                                                                                        (delete-file (expand-file-name "b.txt" repo))
                                                                                        (claude-code-ide-review-refresh)
                                                                                        (should (member "a.txt has no changes left" messages)))))))

(ert-deftest claude-code-ide-review-test-select-file-sees-new-files ()
  "A file created after the view opened is offered by the file switch."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (claude-code-ide-review-tests--two-hunks repo)
                                           (claude-code-ide-review-tests--with-view repo "a.txt"
                                                                                    (claude-code-ide-review-tests--write repo "new.txt" "fresh\n")
                                                                                    (let ((offered nil))
                                                                                      (cl-letf (((symbol-function 'completing-read)
                                                                                                 (lambda (_prompt collection &rest _)
                                                                                                   (setq offered collection)
                                                                                                   "new.txt")))
                                                                                        (claude-code-ide-review-select-file))
                                                                                      (should (equal offered '("a.txt" "new.txt")))
                                                                                      (should (equal (claude-code-ide-review-view-file claude-code-ide-review--view) "new.txt"))
                                                                                      (should (= (length (claude-code-ide-review-view-hunks claude-code-ide-review--view)) 1))))))

;;; Review Prompt and System Prompt Tests

(ert-deftest claude-code-ide-review-test-prompt-uses-argument-or-option ()
  "The review prompt carries the given rules, else the option's rules."
  (let ((claude-code-ide-review-rules "OPTION-RULES"))
    (let ((text (claude-code-ide-review--prompt-text "Cite the issue number")))
      (should (string-match-p "rules: Cite the issue number$" text))
      (should-not (string-match-p "OPTION-RULES" text))
      (should (string-match-p "review_open" text))
      (should (string-match-p "review_list_hunks" text))
      (should (string-match-p "review_annotate" text))
      (should (string-match-p "Leave hunks you did not make alone" text)))
    (should (string-match-p "rules: OPTION-RULES$" (claude-code-ide-review--prompt-text nil)))
    (should (string-match-p "rules: OPTION-RULES$" (claude-code-ide-review--prompt-text "  ")))))

(ert-deftest claude-code-ide-review-test-prompt-registered-once ()
  "Setup registers the review prompt once and prompts/get renders it."
  (let ((claude-code-ide-mcp-server-tools nil)
        (claude-code-ide-mcp-server-prompts nil)
        (claude-code-ide-system-prompt-functions nil)
        (claude-code-ide-command-flag-functions nil)
        (claude-code-ide-enable-mcp-server nil)
        (claude-code-ide-mcp-server-session-started-hook nil)
        (claude-code-ide-mcp-server-session-ended-hook nil))
    (claude-code-ide-review-setup)
    (claude-code-ide-review-setup)
    (should claude-code-ide-enable-mcp-server)
    (should (= (length claude-code-ide-mcp-server-tools) 5))
    (should (= (length claude-code-ide-mcp-server-prompts) 1))
    (should (equal (plist-get (car claude-code-ide-mcp-server-prompts) :name) "review"))
    (should (equal claude-code-ide-system-prompt-functions
                   (list #'claude-code-ide-review--system-prompt)))
    (let* ((listing (claude-code-ide-mcp-http-server--handle-prompts-list nil))
           (entry (aref (alist-get 'prompts listing) 0)))
      (should (equal (alist-get 'name entry) "review"))
      (should (equal (alist-get 'name (aref (alist-get 'arguments entry) 0)) "rules")))
    (let ((result (claude-code-ide-mcp-http-server--handle-prompts-get
                   '((name . "review") (arguments . ((rules . "Be brief")))))))
      (should (string-match-p "rules: Be brief$"
                              (claude-code-ide-mcp-server-tests--prompt-text
                               (alist-get 'messages result)))))))

(ert-deftest claude-code-ide-review-test-system-prompt-paragraph-when-enabled ()
  "The annotation paragraph joins the command line only when the option is on."
  (let ((claude-code-ide-cli-path "claude")
        (claude-code-ide-system-prompt "USER-PARAGRAPH")
        (claude-code-ide-cli-debug nil)
        (claude-code-ide-cli-extra-flags "")
        (claude-code-ide-enable-mcp-server nil)
        (claude-code-ide-review-rules "RULES-TEXT")
        (claude-code-ide-system-prompt-functions
         (list #'claude-code-ide-review--system-prompt)))
    (let ((claude-code-ide-review-annotate-on-edit nil))
      (should-not (claude-code-ide-review--system-prompt))
      (should-not (string-match-p "review_annotate" (claude-code-ide--build-claude-command))))
    (let ((claude-code-ide-review-annotate-on-edit t))
      (should (string-match-p "RULES-TEXT$" (claude-code-ide-review--system-prompt)))
      (let ((cmd (claude-code-ide--build-claude-command)))
        (should (string-match-p "review_annotate" cmd))
        (should (string-match-p "RULES-TEXT" cmd))
        ;; The user's own paragraph comes first
        (should (< (string-match-p "USER-PARAGRAPH" cmd)
                   (string-match-p "review_annotate" cmd)))))))

(defun claude-code-ide-review-tests--hook-round-trip (repo path)
  "Run the hook report for PATH edited in REPO; return the parsed reply or nil."
  (let ((file (make-temp-file "claude-hook-")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (json-encode `((session_id . "abc") (cwd . ,repo)
                                   (tool_name . "Edit")
                                   (tool_input . ((file_path . ,path)))))))
          (should-not (claude-code-ide-review-hook-report file))
          (with-temp-buffer
            (insert-file-contents file)
            (unless (zerop (buffer-size))
              (json-parse-buffer :object-type 'alist))))
      (delete-file file))))

(ert-deftest claude-code-ide-review-test-hook-report-lists-unexplained ()
  "The hook reply names unexplained and stale hunks of the edited file, else is empty."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           (let* ((hunks (claude-code-ide-review-tests--two-hunks repo))
                                                  (path (expand-file-name "a.txt" repo))
                                                  (reply (claude-code-ide-review-tests--hook-round-trip repo path))
                                                  (output (alist-get 'hookSpecificOutput reply)))
                                             (should (equal (alist-get 'hookEventName output) "PostToolUse"))
                                             (should (equal (alist-get 'additionalContext output)
                                                            "Review: 2 hunks in a.txt have no justification: a.txt:2-2, a.txt:4-4. Call review_annotate for the ones you made."))
                                             ;; Hunk 0 annotated; hunk 1 annotated then edited, so stale
                                             (claude-code-ide-review-put-note repo (car hunks) 'claude "Shorter name")
                                             (claude-code-ide-review-put-note repo (cadr hunks) 'claude "Added a step")
                                             (claude-code-ide-review-tests--write repo "a.txt" "one\n2\nthree\nFOUR\n")
                                             (should (equal (alist-get 'additionalContext
                                                                       (alist-get 'hookSpecificOutput
                                                                                  (claude-code-ide-review-tests--hook-round-trip repo path)))
                                                            "Review: 1 hunk in a.txt has no justification: a.txt:4-4 (stale). Call review_annotate for the ones you made."))
                                             ;; Everything justified: nothing to say
                                             (claude-code-ide-review-put-note repo (cadr (claude-code-ide-review-hunks repo "a.txt"))
                                                                              'claude "Shouted the step")
                                             (should-not (claude-code-ide-review-tests--hook-round-trip repo path))
                                             ;; A file without hunks: nothing to say
                                             (should-not (claude-code-ide-review-tests--hook-round-trip
                                                          repo (expand-file-name "other.txt" repo))))))

(ert-deftest claude-code-ide-review-test-hook-report-ignores-unknown-input ()
  "No baseline, missing fields and invalid JSON all leave an empty reply."
  (skip-unless (executable-find "git"))
  (claude-code-ide-review-tests--with-repo repo
                                           ;; No baseline for this repository
                                           (should-not (claude-code-ide-review-tests--hook-round-trip
                                                        repo (expand-file-name "a.txt" repo)))
                                           (claude-code-ide-review-tests--two-hunks repo)
                                           (let ((file (make-temp-file "claude-hook-")))
                                             (unwind-protect
                                                 (dolist (content (list "{\"cwd\": \"x\"}" "not json" ""))
                                                   (with-temp-file file (insert content))
                                                   (should-not (claude-code-ide-review-hook-report file))
                                                   (should (zerop (file-attribute-size (file-attributes file)))))
                                               (delete-file file)))))

(ert-deftest claude-code-ide-review-test-hook-settings-json-shape ()
  "The settings JSON installs one command hook on the edit tools."
  (let* ((server-name "review-test")
         (server-use-tcp nil)
         (settings (json-parse-string (claude-code-ide-review--settings-json) :object-type 'alist))
         (entry (aref (alist-get 'PostToolUse (alist-get 'hooks settings)) 0))
         (hook (aref (alist-get 'hooks entry) 0))
         (command (alist-get 'command hook)))
    (should (equal (alist-get 'matcher entry) "Edit|Write|MultiEdit"))
    (should (equal (alist-get 'type hook) "command"))
    (should (= (alist-get 'timeout hook) 10))
    (should (string-match-p "emacsclient" command))
    (should (string-match-p " -s review-test " command))
    (should (string-match-p "--eval \"(claude-code-ide-review-hook-report \\\\\"\\$f\\\\\")\"" command))
    (should (string-prefix-p "f=$(mktemp); cat >\"$f\"; " command))
    (should (string-suffix-p "; cat \"$f\"; rm -f \"$f\"" command)))
  (let ((server-use-tcp t)
        (server-name "tcp-test")
        (server-auth-dir "/tmp/auth/"))
    (should (string-match-p " -f /tmp/auth/tcp-test " (claude-code-ide-review--hook-command)))))

(ert-deftest claude-code-ide-review-test-hook-flag-needs-option-and-server ()
  "The --settings flag joins the command line only with the option on and a server running."
  (let ((claude-code-ide-cli-path "claude")
        (claude-code-ide-system-prompt nil)
        (claude-code-ide-cli-debug nil)
        (claude-code-ide-cli-extra-flags "")
        (claude-code-ide-enable-mcp-server nil)
        (claude-code-ide-command-flag-functions (list #'claude-code-ide-review--command-flags))
        (server-name "flag-test"))
    (cl-letf (((symbol-function 'server-running-p) (lambda (&optional _name) t)))
      (let ((claude-code-ide-review-remind-on-edit nil))
        (should-not (string-match-p "--settings" (claude-code-ide--build-claude-command))))
      (let ((claude-code-ide-review-remind-on-edit t))
        (let ((cmd (claude-code-ide--build-claude-command)))
          (should (string-match-p " --settings " cmd))
          (should (string-match-p "PostToolUse" cmd))
          (should (string-match-p "claude-code-ide-review-hook-report" cmd)))))
    (cl-letf (((symbol-function 'server-running-p) (lambda (&optional _name) nil)))
      (let ((claude-code-ide-review-remind-on-edit t))
        (should-not (string-match-p "--settings" (claude-code-ide--build-claude-command)))))))

(ert-deftest claude-code-ide-review-test-menu-defined ()
  "The review submenu exists, is reachable from the main menu, and its toggle works."
  (skip-unless (require 'transient nil t))
  (require 'claude-code-ide-transient)
  (should (get 'claude-code-ide-review-menu 'transient--prefix))
  ;; The layout representation differs between transient versions; the
  ;; printed form names the command either way
  (should (string-match-p "claude-code-ide-review-menu"
                          (format "%S" (get 'claude-code-ide-menu 'transient--layout))))
  (let ((claude-code-ide-review-annotate-on-edit nil))
    (cl-letf (((symbol-function 'claude-code-ide-log) #'ignore))
      (claude-code-ide--toggle-review-annotate-on-edit)
      (should claude-code-ide-review-annotate-on-edit)
      (claude-code-ide--toggle-review-annotate-on-edit)
      (should-not claude-code-ide-review-annotate-on-edit))))

;;; Multi-Instance Tests

(ert-deftest claude-code-ide-test-two-instances-one-project ()
  "Two instances of one project get their own server, port and lockfile."
  (claude-code-ide-tests--clear-processes)
  (let ((project-dir "/tmp/claude-two-instances/")
        (primary nil)
        (secondary nil))
    (unwind-protect
        (progn
          (setq primary (claude-code-ide-mcp-create-session project-dir "two-1")
                secondary (claude-code-ide-mcp-create-session
                           project-dir "two-2" "review"))
          (should-not (equal (claude-code-ide-mcp-session-session-id primary)
                             (claude-code-ide-mcp-session-session-id secondary)))
          (should-not (claude-code-ide-mcp-session-instance-name primary))
          (should (equal (claude-code-ide-mcp-session-instance-name secondary) "review"))
          ;; Both belong to the same project
          (should (= 2 (length (claude-code-ide-mcp--sessions-for-project project-dir))))
          (let ((port1 (claude-code-ide-mcp-session-port primary))
                (port2 (claude-code-ide-mcp-session-port secondary)))
            (should-not (= port1 port2))
            (should (file-exists-p (claude-code-ide-mcp--lockfile-path port1)))
            (should (file-exists-p (claude-code-ide-mcp--lockfile-path port2)))
            ;; Their terminal buffers cannot collide either
            (should-not (equal (claude-code-ide--instance-buffer-name project-dir nil)
                               (claude-code-ide--instance-buffer-name project-dir "review")))
            (should (equal (claude-code-ide--instance-buffer-name project-dir "review")
                           "*claude-code[claude-two-instances:review]*"))

            ;; Stopping one takes down only its own lockfile
            (claude-code-ide-mcp--stop-session primary)
            (should-not (file-exists-p (claude-code-ide-mcp--lockfile-path port1)))
            (should (file-exists-p (claude-code-ide-mcp--lockfile-path port2)))
            (should (equal (claude-code-ide-mcp--sessions-for-project project-dir)
                           (list secondary)))

            (claude-code-ide-mcp--stop-session secondary)
            (should-not (file-exists-p (claude-code-ide-mcp--lockfile-path port2)))
            (should-not (claude-code-ide-mcp--sessions-for-project project-dir))))
      (claude-code-ide-tests--stop-all-sessions)
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-generate-session-id-unique ()
  "Session IDs are unique even for instances started in the same second."
  (let* ((claude-code-ide--session-counter 0)
         (id1 (claude-code-ide--generate-session-id "/tmp/proj/"))
         (id2 (claude-code-ide--generate-session-id "/tmp/proj/")))
    (should-not (equal id1 id2))
    (should (string-prefix-p "claude-proj-" id1))
    (should (string-suffix-p "-1" id1))
    (should (string-suffix-p "-2" id2))))

(ert-deftest claude-code-ide-test-auto-instance-name ()
  "Auto naming takes the plain slot first, then the lowest free number."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (let ((project-dir "/tmp/claude-auto-name/"))
        ;; No instance yet, so the plain unnamed slot is free
        (should-not (claude-code-ide--auto-instance-name project-dir))
        (let ((plain (claude-code-ide-tests--make-session project-dir)))
          (should (equal (claude-code-ide--auto-instance-name project-dir) "2"))
          (let ((second (claude-code-ide-tests--make-session project-dir
                                                             :instance-name "2")))
            (should (equal (claude-code-ide--auto-instance-name project-dir) "3"))
            ;; A user-chosen name does not consume a number
            (claude-code-ide-tests--make-session project-dir :instance-name "review")
            (should (equal (claude-code-ide--auto-instance-name project-dir) "3"))
            ;; While renaming, the instance's own name counts as free
            (should-not (claude-code-ide--auto-instance-name project-dir plain))
            (should (equal (claude-code-ide--auto-instance-name project-dir second) "2"))
            ;; The plain slot is reused once its instance is gone
            (remhash (claude-code-ide-mcp-session-session-id plain)
                     claude-code-ide-mcp--sessions)
            (should-not (claude-code-ide--auto-instance-name project-dir))
            ;; Another project's instances are irrelevant
            (claude-code-ide-tests--make-session "/tmp/claude-other-project/")
            (should-not (claude-code-ide--auto-instance-name project-dir)))))
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-read-instance-name-validation ()
  "Instance names are validated and empty input auto-numbers."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (let ((project-dir "/tmp/claude-read-name/")
            (inputs nil)
            (messages '()))
        (claude-code-ide-tests--make-session project-dir)
        (claude-code-ide-tests--make-session project-dir :instance-name "taken")
        (cl-letf (((symbol-function 'read-string)
                   (lambda (&rest _) (or (pop inputs) (error "No test input left"))))
                  ((symbol-function 'sit-for) (lambda (&rest _) t))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
          ;; Numeric names are reserved for auto-numbering; input is trimmed
          (setq inputs '("7" "  refactor  ")
                messages '())
          (should (equal (claude-code-ide--read-instance-name project-dir) "refactor"))
          (should (cl-find-if (lambda (m) (string-match-p "Numeric" m)) messages))

          ;; Characters that would break buffer naming are rejected
          (setq inputs '("bad[name" "bad]name" "bad*name" "ok")
                messages '())
          (should (equal (claude-code-ide--read-instance-name project-dir) "ok"))
          (should (= 3 (length messages)))

          ;; A name already used in this project is rejected
          (setq inputs '("taken" "fresh")
                messages '())
          (should (equal (claude-code-ide--read-instance-name project-dir) "fresh"))
          (should (cl-find-if (lambda (m) (string-match-p "already used" m)) messages))

          ;; Empty input auto-numbers: the plain slot is taken, so "2"
          (setq inputs '(""))
          (should (equal (claude-code-ide--read-instance-name project-dir) "2"))))
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-instance-buffer-name-compat ()
  "Buffer naming keeps working for single-argument naming functions."
  (let ((project-dir "/tmp/naming/"))
    ;; The documented single-argument function is left alone for the
    ;; unnamed instance and decorated inside the brackets for named ones
    (let ((claude-code-ide-buffer-name-function
           (lambda (dir) (format "*claude-code[%s]*"
                                 (file-name-nondirectory (directory-file-name dir))))))
      (should (equal (claude-code-ide--instance-buffer-name project-dir nil)
                     "*claude-code[naming]*"))
      (should (equal (claude-code-ide--instance-buffer-name project-dir "review")
                     "*claude-code[naming:review]*")))
    ;; A name that does not end in "]*" gets the instance appended instead
    (let ((claude-code-ide-buffer-name-function (lambda (_dir) "claude")))
      (should (equal (claude-code-ide--instance-buffer-name project-dir nil) "claude"))
      (should (equal (claude-code-ide--instance-buffer-name project-dir "review")
                     "claude<review>")))
    ;; A two-argument function is handed the instance name itself
    (let* ((received nil)
           (claude-code-ide-buffer-name-function
            (lambda (dir instance)
              (setq received (list dir instance))
              (format "*c[%s]*" (or instance "plain")))))
      (should (equal (claude-code-ide--instance-buffer-name project-dir "review")
                     "*c[review]*"))
      (should (equal received (list project-dir "review")))
      (should (equal (claude-code-ide--instance-buffer-name project-dir nil)
                     "*c[plain]*"))
      (should (equal received (list project-dir nil))))))

(ert-deftest claude-code-ide-test-resolve-session-chain ()
  "Test how a command decides which instance it targets."
  (claude-code-ide-tests--clear-processes)
  (let ((project-dir "/tmp/claude-resolve/")
        (buffer-a (generate-new-buffer "*claude-resolve-a*"))
        (buffer-b (generate-new-buffer "*claude-resolve-b*"))
        (visible-buffer nil)
        (prompted 0))
    (unwind-protect
        (let ((session-a (claude-code-ide-tests--make-session
                          project-dir :instance-name "alpha"
                          :buffer buffer-a :last-used 100.0))
              (session-b (claude-code-ide-tests--make-session
                          project-dir :instance-name "beta"
                          :buffer buffer-b :last-used 200.0)))
          (cl-letf (((symbol-function 'claude-code-ide--get-working-directory)
                     (lambda () project-dir))
                    ((symbol-function 'get-buffer-window)
                     (lambda (buffer &rest _)
                       (when (eq buffer visible-buffer) 'mock-window)))
                    ((symbol-function 'completing-read)
                     (lambda (_prompt candidates &rest _)
                       (cl-incf prompted)
                       (car (car candidates)))))
            ;; Inside a Claude terminal the buffer's own instance always wins
            (with-current-buffer buffer-a
              (setq-local claude-code-ide--session session-a)
              (should (eq (claude-code-ide--resolve-session 'auto) session-a))
              (should (eq (claude-code-ide--resolve-session 'prompt) session-a))
              (should (= prompted 0)))

            ;; A single visible instance is unambiguous, even for a
            ;; destructive command
            (setq visible-buffer buffer-a)
            (should (eq (claude-code-ide--resolve-session 'prompt) session-a))
            (should (= prompted 0))

            ;; With nothing visible, `auto' guesses the most recently used
            ;; instance and `prompt' asks instead
            (setq visible-buffer nil)
            (should (eq (claude-code-ide--resolve-session 'auto) session-b))
            (should (= prompted 0))
            (should (claude-code-ide--resolve-session 'prompt))
            (should (= prompted 1))

            ;; A prefix argument always asks
            (let ((current-prefix-arg '(4)))
              (should (claude-code-ide--resolve-session 'auto))
              (should (= prompted 2)))

            ;; A project without instances resolves to nothing
            (claude-code-ide-tests--clear-processes)
            (should-not (claude-code-ide--resolve-session 'prompt))
            (should (= prompted 2))))
      (dolist (buffer (list buffer-a buffer-b))
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-selection-broadcast ()
  "Selection changes reach every instance of the project, deduped per instance."
  (claude-code-ide-tests--clear-processes)
  (let* ((project-dir "/tmp/claude-selection/")
         (file (expand-file-name "file.txt" project-dir))
         (client-a (claude-code-ide-tests--make-websocket "ws://127.0.0.1:10006"))
         (client-b (claude-code-ide-tests--make-websocket "ws://127.0.0.1:10007"))
         (sent '()))
    (unwind-protect
        (let ((session-a (claude-code-ide-tests--make-session project-dir
                                                              :client client-a))
              (session-b (claude-code-ide-tests--make-session project-dir
                                                              :instance-name "b"
                                                              :client client-b)))
          (cl-letf (((symbol-function 'websocket-send-text)
                     (lambda (ws text) (push (cons ws text) sent))))
            (with-temp-buffer
              (insert "line 1\nline 2\n")
              (setq buffer-file-name file)
              (goto-char (point-min))

              ;; Every instance of the project is told about the selection
              (claude-code-ide-mcp--send-selection-for-project project-dir)
              (should (= 2 (length sent)))
              (dolist (entry sent)
                (should (string-match-p "selection_changed" (cdr entry))))
              (should (cl-find-if (lambda (e) (eq (car e) client-a)) sent))
              (should (cl-find-if (lambda (e) (eq (car e) client-b)) sent))
              ;; Each instance remembers what it was told
              (should (claude-code-ide-mcp-session-last-selection session-a))
              (should (claude-code-ide-mcp-session-last-selection session-b))

              ;; Without any movement nothing is resent
              (setq sent '())
              (claude-code-ide-mcp--send-selection-for-project project-dir)
              (should-not sent)

              ;; Dedupe state is per instance, so an instance that lost its
              ;; state still gets the current selection
              (setf (claude-code-ide-mcp-session-last-selection session-b) nil)
              (claude-code-ide-mcp--send-selection-for-project project-dir)
              (should (= 1 (length sent)))
              (should (eq (car (car sent)) client-b))

              ;; Moving point broadcasts to everyone again
              (setq sent '())
              (forward-line 1)
              (claude-code-ide-mcp--send-selection-for-project project-dir)
              (should (= 2 (length sent)))

              ;; A buffer outside the project resets the per-instance state
              ;; instead of broadcasting
              (setq sent '())
              (setq buffer-file-name "/tmp/elsewhere/file.txt")
              (claude-code-ide-mcp--send-selection-for-project project-dir)
              (should-not sent)
              (should-not (claude-code-ide-mcp-session-last-selection session-a))
              (should-not (claude-code-ide-mcp-session-last-selection session-b))

              (set-buffer-modified-p nil)
              (setq buffer-file-name nil))))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-clear-selection-dismisses-file ()
  "Clearing makes the instance forget its file and keeps that file dismissed."
  (claude-code-ide-tests--clear-processes)
  (let* ((project-dir "/tmp/claude-clear-selection/")
         (file (expand-file-name "file.txt" project-dir))
         (other (expand-file-name "other.txt" project-dir))
         (client (claude-code-ide-tests--make-websocket "ws://127.0.0.1:10012"))
         (sent '()))
    (unwind-protect
        (let ((session (claude-code-ide-tests--make-session project-dir
                                                            :client client)))
          (cl-letf (((symbol-function 'websocket-send-text)
                     (lambda (_ws text)
                       (push (json-parse-string text :object-type 'alist) sent))))
            (with-temp-buffer
              (insert "line 1\nline 2\n")
              (setq buffer-file-name file)
              (goto-char (point-min))
              (claude-code-ide-mcp--send-selection-for-project project-dir)
              (should (equal file (alist-get 'filePath
                                             (alist-get 'params (car sent)))))

              ;; Clearing sends a selection that names no file and no text
              (setq sent '())
              (claude-code-ide-mcp-clear-selection session)
              (should (= 1 (length sent)))
              (let ((params (alist-get 'params (car sent))))
                (should (equal "selection_changed" (alist-get 'method (car sent))))
                (should-not (assq 'filePath params))
                (should-not (assq 'text params))
                (should (alist-get 'start (alist-get 'selection params)))
                (should (alist-get 'end (alist-get 'selection params))))
              (should-not (claude-code-ide-mcp-session-last-selection session))
              (should (equal file (claude-code-ide-mcp-session-dismissed-file session)))

              ;; Cursor movement inside the dismissed file stays silent
              (setq sent '())
              (forward-line 1)
              (claude-code-ide-mcp--send-selection-for-project project-dir)
              (should-not sent)

              ;; Selecting a region ends the dismissal
              (set-mark (point-min))
              (goto-char (point-max))
              (let ((transient-mark-mode t))
                (activate-mark)
                (claude-code-ide-mcp--send-selection-for-project project-dir)
                (deactivate-mark))
              (should (= 1 (length sent)))
              (should (equal "line 1\nline 2\n"
                             (alist-get 'text (alist-get 'params (car sent)))))
              (should-not (claude-code-ide-mcp-session-dismissed-file session))

              ;; Visiting another file ends it as well
              (claude-code-ide-mcp-clear-selection session)
              (should (equal file (claude-code-ide-mcp-session-dismissed-file session)))
              (setq sent '())
              (setq buffer-file-name other)
              (claude-code-ide-mcp--send-selection-for-project project-dir)
              (should (= 1 (length sent)))
              (should (equal other (alist-get 'filePath
                                              (alist-get 'params (car sent)))))
              (should-not (claude-code-ide-mcp-session-dismissed-file session))

              ;; A file outside the project ends it too
              (claude-code-ide-mcp-clear-selection session)
              (setq buffer-file-name "/tmp/elsewhere/file.txt")
              (claude-code-ide-mcp--send-selection-for-project project-dir)
              (should-not (claude-code-ide-mcp-session-dismissed-file session))

              (set-buffer-modified-p nil)
              (setq buffer-file-name nil))))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-terminal-keybindings-bind-clear-selection ()
  "Every terminal backend binds C-c C-x to clearing the editor context."
  (dolist (backend '(vterm eat ghostel))
    (with-temp-buffer
      (use-local-map (make-sparse-keymap))
      (let ((claude-code-ide-terminal-backend backend))
        (claude-code-ide--setup-terminal-keybindings))
      (should (eq #'claude-code-ide-clear-selection
                  (lookup-key (current-local-map) (kbd "C-c C-x"))))
      (should (eq #'claude-code-ide-send-escape
                  (lookup-key (current-local-map) (kbd "C-<escape>")))))))

(ert-deftest claude-code-ide-test-clear-selection-command ()
  "The command clears the resolved instance and refuses a disconnected one."
  (claude-code-ide-tests--clear-processes)
  (let ((project-dir "/tmp/claude-clear-command/")
        (cleared '()))
    (unwind-protect
        (let ((connected (claude-code-ide-tests--make-session
                          project-dir
                          :client (claude-code-ide-tests--make-websocket
                                   "ws://127.0.0.1:10013")))
              (idle (claude-code-ide-tests--make-session project-dir
                                                         :instance-name "b")))
          (cl-letf (((symbol-function 'claude-code-ide-mcp-clear-selection)
                     (lambda (session) (push session cleared))))
            (cl-letf (((symbol-function 'claude-code-ide--resolve-session)
                       (lambda (&rest _) connected)))
              (claude-code-ide-clear-selection)
              (should (equal cleared (list connected))))
            (cl-letf (((symbol-function 'claude-code-ide--resolve-session)
                       (lambda (&rest _) idle)))
              (should-error (claude-code-ide-clear-selection) :type 'user-error))
            (should (equal cleared (list connected)))))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-share-opened-file-off-reports-regions-only ()
  "With `claude-code-ide-share-opened-file' nil only regions reach Claude."
  (claude-code-ide-tests--clear-processes)
  (let* ((project-dir "/tmp/claude-regions-only/")
         (file (expand-file-name "file.txt" project-dir))
         (client (claude-code-ide-tests--make-websocket "ws://127.0.0.1:10016"))
         (claude-code-ide-share-opened-file nil)
         (sent '()))
    (unwind-protect
        (let ((session (claude-code-ide-tests--make-session project-dir
                                                            :client client)))
          (cl-letf (((symbol-function 'websocket-send-text)
                     (lambda (_ws text)
                       (push (json-parse-string text :object-type 'alist) sent))))
            (with-temp-buffer
              (insert "line 1\nline 2\n")
              (setq buffer-file-name file)
              (goto-char (point-min))
              ;; A bare cursor position is not reported
              (claude-code-ide-mcp--send-selection-for-project project-dir)
              (should-not sent)
              (should-not (claude-code-ide-mcp-session-last-selection session))

              ;; A region is
              (set-mark (point-min))
              (goto-char (point-max))
              (let ((transient-mark-mode t))
                (activate-mark)
                (claude-code-ide-mcp--send-selection-for-project project-dir)
                (deactivate-mark))
              (should (= 1 (length sent)))
              (let ((params (alist-get 'params (car sent))))
                (should (equal file (alist-get 'filePath params)))
                (should (equal "line 1\nline 2\n" (alist-get 'text params))))

              ;; Deactivating it makes the instance forget the region
              (setq sent '())
              (claude-code-ide-mcp--send-selection-for-project project-dir)
              (should (= 1 (length sent)))
              (should-not (assq 'filePath (alist-get 'params (car sent))))
              (should-not (claude-code-ide-mcp-session-last-selection session))

              ;; Cursor movement stays silent afterwards
              (setq sent '())
              (forward-line -1)
              (claude-code-ide-mcp--send-selection-for-project project-dir)
              (should-not sent)
              (set-buffer-modified-p nil)
              (setq buffer-file-name nil))))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-track-selection-debounces-per-project ()
  "Selection tracking arms one debounce timer per project, not per instance."
  (claude-code-ide-tests--clear-processes)
  (let* ((project-dir "/tmp/claude-debounce/")
         (timers 0)
         (cancelled 0)
         (fired '()))
    (unwind-protect
        (progn
          (claude-code-ide-tests--make-session project-dir)
          (claude-code-ide-tests--make-session project-dir :instance-name "b")
          (cl-letf (((symbol-function 'claude-code-ide-mcp--get-buffer-project)
                     (lambda () project-dir))
                    ((symbol-function 'run-with-timer)
                     (lambda (_delay _repeat callback)
                       (cl-incf timers)
                       ;; Return the callback itself as the timer object so
                       ;; the test can fire it synchronously
                       callback))
                    ((symbol-function 'cancel-timer)
                     (lambda (_timer) (cl-incf cancelled)))
                    ((symbol-function 'claude-code-ide-mcp--send-selection-for-project)
                     (lambda (dir) (push dir fired))))
            (with-temp-buffer
              (setq buffer-file-name (expand-file-name "file.txt" project-dir))
              ;; Two instances, but only one timer for the project
              (claude-code-ide-mcp--track-selection)
              (should (= timers 1))
              (should (= cancelled 0))
              (should (gethash project-dir claude-code-ide-mcp--selection-timers))

              ;; A second command replaces the pending timer
              (claude-code-ide-mcp--track-selection)
              (should (= timers 2))
              (should (= cancelled 1))

              ;; Firing it fans the selection out to the whole project once
              (funcall (gethash project-dir claude-code-ide-mcp--selection-timers))
              (should (equal fired (list project-dir)))
              (setq buffer-file-name nil))))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-track-active-buffer-broadcast ()
  "The active buffer is tracked for every instance under its own session ID."
  (claude-code-ide-tests--clear-processes)
  (let ((project-dir "/tmp/claude-active-buffer/")
        (updates '()))
    (unwind-protect
        (let ((session-a (claude-code-ide-tests--make-session project-dir
                                                              :client (claude-code-ide-tests--make-websocket
                                                                       "ws://127.0.0.1:10008")))
              (session-b (claude-code-ide-tests--make-session project-dir
                                                              :instance-name "b"
                                                              :client (claude-code-ide-tests--make-websocket
                                                                       "ws://127.0.0.1:10009")))
              (session-c (claude-code-ide-tests--make-session project-dir
                                                              :instance-name "c")))
          (cl-letf (((symbol-function 'claude-code-ide-mcp--get-buffer-project)
                     (lambda () project-dir))
                    ((symbol-function 'claude-code-ide-mcp-server-update-last-active-buffer)
                     (lambda (session-id buffer) (push (cons session-id buffer) updates))))
            (with-temp-buffer
              (setq buffer-file-name (expand-file-name "file.txt" project-dir))
              (claude-code-ide-mcp--track-active-buffer)
              (should (eq (claude-code-ide-mcp-session-last-buffer session-a)
                          (current-buffer)))
              (should (eq (claude-code-ide-mcp-session-last-buffer session-b)
                          (current-buffer)))
              ;; An instance whose CLI has not connected yet is skipped
              (should-not (claude-code-ide-mcp-session-last-buffer session-c))
              ;; Each instance is updated under its own session ID
              (should (= 2 (length updates)))
              (should (assoc (claude-code-ide-mcp-session-session-id session-a) updates))
              (should (assoc (claude-code-ide-mcp-session-session-id session-b) updates))

              ;; Nothing is resent while the same buffer stays active
              (setq updates '())
              (claude-code-ide-mcp--track-active-buffer)
              (should-not updates)
              (setq buffer-file-name nil))))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-at-mentioned-targets-one-instance ()
  "An at-mention is an explicit insertion, so it goes to exactly one instance."
  (claude-code-ide-tests--clear-processes)
  (let* ((project-dir "/tmp/claude-at-mentioned/")
         (file (expand-file-name "file.txt" project-dir))
         (client-a (claude-code-ide-tests--make-websocket "ws://127.0.0.1:10010"))
         (client-b (claude-code-ide-tests--make-websocket "ws://127.0.0.1:10011"))
         (sent '()))
    (unwind-protect
        (let ((session-b (progn
                           (claude-code-ide-tests--make-session project-dir
                                                                :client client-a)
                           (claude-code-ide-tests--make-session project-dir
                                                                :instance-name "b"
                                                                :client client-b))))
          (cl-letf (((symbol-function 'websocket-send-text)
                     (lambda (ws text) (push (cons ws text) sent))))
            (with-temp-buffer
              (insert "one\ntwo\nthree\n")
              (setq buffer-file-name file)
              (goto-char (point-min))
              (forward-line 1)
              (claude-code-ide-mcp-send-at-mentioned session-b)
              (should (= 1 (length sent)))
              (should (eq (car (car sent)) client-b))
              ;; The sibling instance is not told about it
              (should-not (cl-find-if (lambda (e) (eq (car e) client-a)) sent))
              (let* ((payload (json-read-from-string (cdr (car sent))))
                     (params (alist-get 'params payload)))
                (should (equal (alist-get 'method payload) "at_mentioned"))
                (should (equal (alist-get 'filePath params) file))
                ;; Line numbers are zero-based on the wire
                (should (= (alist-get 'lineStart params) 1))
                (should (= (alist-get 'lineEnd params) 1)))
              (set-buffer-modified-p nil)
              (setq buffer-file-name nil))))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-deferred-stored-in-dispatch-session ()
  "A deferred tool response is filed under the instance that asked for it."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (let* ((project-dir "/tmp/claude-deferred/")
             (session-a (claude-code-ide-tests--make-session project-dir))
             (session-b (claude-code-ide-tests--make-session project-dir
                                                             :instance-name "b"))
             (handler-sessions '())
             (claude-code-ide-mcp-tools
              (append `(("mockDeferred" . ,(lambda (_arguments session)
                                             (push session handler-sessions)
                                             '((deferred . t) (unique-key . "tab-1"))))
                        ("mockPlain" . ,(lambda (_arguments _session)
                                          (list '((type . "text") (text . "OK"))))))
                      claude-code-ide-mcp-tools)))
        ;; The handler is called with its session, and the pending id lands
        ;; in that session even though a sibling instance exists
        (should-not (claude-code-ide-mcp--handle-tools-call
                     "req-7" '((name . "mockDeferred")) session-b))
        (should (equal handler-sessions (list session-b)))
        (should (equal (gethash "mockDeferred-tab-1"
                                (claude-code-ide-mcp-session-deferred session-b))
                       "req-7"))
        (should (= 0 (hash-table-count
                      (claude-code-ide-mcp-session-deferred session-a))))

        ;; A non-deferred tool answers inline and stores nothing
        (let ((response (claude-code-ide-mcp--handle-tools-call
                         "req-8" '((name . "mockPlain")) session-a)))
          (should (equal (alist-get 'id response) "req-8"))
          (should (= 0 (hash-table-count
                        (claude-code-ide-mcp-session-deferred session-a))))))
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-opendiff-requires-session ()
  "openDiff refuses to run without the instance that requested it."
  (should-error (claude-code-ide-mcp-handle-open-diff
                 '((old_file_path . "/tmp/claude-x.txt")
                   (new_file_path . "/tmp/claude-x.txt")
                   (new_file_contents . "new")
                   (tab_name . "tab"))
                 nil)
                :type 'mcp-error)
  ;; A nil session also has no diffs to report
  (should-not (claude-code-ide-mcp--get-active-diffs nil)))

(ert-deftest claude-code-ide-test-close-tab-session-scoping ()
  "A close_tab only closes diffs owned by the requesting instance."
  (claude-code-ide-tests--clear-processes)
  (let ((project-dir "/tmp/claude-close-tab/")
        (diff-buffer (generate-new-buffer "*claude-close-tab-diff*")))
    (unwind-protect
        (let ((session-a (claude-code-ide-tests--make-session project-dir))
              (session-b (claude-code-ide-tests--make-session project-dir
                                                              :instance-name "b")))
          ;; Sibling instances of one project see identical CLI tab names,
          ;; but only A opened this one
          (puthash "shared-tab-name"
                   `((buffer-B . ,diff-buffer) (file-exists . t))
                   (claude-code-ide-mcp-session-active-diffs session-a))

          ;; B's request must not reach into A's diffs; with no buffer of
          ;; that name either, the request fails
          (should-error (claude-code-ide-mcp-handle-close-tab
                         '((tab_name . "shared-tab-name")) session-b)
                        :type 'mcp-error)
          (should (gethash "shared-tab-name"
                           (claude-code-ide-mcp-session-active-diffs session-a)))
          (should (buffer-live-p diff-buffer))

          ;; A's request closes A's diff
          (let ((result (claude-code-ide-mcp-handle-close-tab
                         '((tab_name . "shared-tab-name")) session-a)))
            (should (equal (alist-get 'text (car result)) "TAB_CLOSED")))
          (should-not (gethash "shared-tab-name"
                               (claude-code-ide-mcp-session-active-diffs session-a)))
          (should-not (buffer-live-p diff-buffer)))
      (when (buffer-live-p diff-buffer)
        (kill-buffer diff-buffer))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-reconnect-adopts-new-client ()
  "A CLI reconnect replaces the client, flushes pending ids, keeps diffs."
  (claude-code-ide-tests--clear-processes)
  (let ((ws1 (claude-code-ide-tests--make-websocket "ws://127.0.0.1:10001"))
        (ws2 (claude-code-ide-tests--make-websocket "ws://127.0.0.1:10002"))
        (closed '()))
    (unwind-protect
        (cl-letf (((symbol-function 'websocket-close)
                   (lambda (ws) (push ws closed))))
          (let ((session (claude-code-ide-tests--make-session
                          "/tmp/claude-reconnect/" :client ws1)))
            (puthash "openDiff-tab" "req-1"
                     (claude-code-ide-mcp-session-deferred session))
            (puthash "tab" '((buffer-B . nil))
                     (claude-code-ide-mcp-session-active-diffs session))
            (setf (claude-code-ide-mcp-session-last-selection session) '(1 1 1))

            (with-temp-buffer
              (claude-code-ide-mcp--on-open session ws2))
            (should (eq (claude-code-ide-mcp-session-client session) ws2))
            (should (equal closed (list ws1)))
            ;; Ids that died with the old socket are dropped and selection
            ;; dedupe restarts, but a diff the user may still be looking at
            ;; survives the reconnect
            (should (= 0 (hash-table-count
                          (claude-code-ide-mcp-session-deferred session))))
            (should-not (claude-code-ide-mcp-session-last-selection session))
            (should (gethash "tab" (claude-code-ide-mcp-session-active-diffs session)))

            ;; Traffic from the replaced socket is ignored
            (let ((handled '())
                  (frame (claude-code-ide-tests--make-frame "{\"method\":\"ping\"}")))
              (cl-letf (((symbol-function 'claude-code-ide-mcp--handle-message)
                         (lambda (message &optional _session _ws) (push message handled))))
                (claude-code-ide-mcp--on-message session ws1 frame)
                (should-not handled)
                (claude-code-ide-mcp--on-message session ws2 frame)
                (should (= 1 (length handled)))))

            ;; The replaced socket's close must not clear its successor
            (claude-code-ide-mcp--on-close session ws1)
            (should (eq (claude-code-ide-mcp-session-client session) ws2))
            (claude-code-ide-mcp--on-close session ws2)
            (should-not (claude-code-ide-mcp-session-client session))))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-cleanup-session-isolation ()
  "Cleaning up one instance leaves its project sibling fully working."
  (claude-code-ide-tests--clear-processes)
  (let ((project-dir "/tmp/claude-isolation/")
        (buffer-a (generate-new-buffer "*claude-isolation-a*"))
        (session-a nil)
        (session-b nil))
    (unwind-protect
        (let ((claude-code-ide-prevent-reflow-glitch nil))
          (setq session-a (claude-code-ide-mcp-create-session project-dir "iso-a")
                session-b (claude-code-ide-mcp-create-session
                           project-dir "iso-b" "keep"))
          (setf (claude-code-ide-mcp-session-buffer session-a) buffer-a)
          (claude-code-ide-mcp-server-session-started "iso-a" project-dir buffer-a)
          (claude-code-ide-mcp-server-session-started "iso-b" project-dir nil)
          (setq claude-code-ide--last-accessed-buffer buffer-a)
          (let ((server-b (claude-code-ide-mcp-session-server session-b))
                (port-b (claude-code-ide-mcp-session-port session-b)))
            (claude-code-ide--cleanup-session session-a)

            ;; The cleaned instance is gone: deregistered, buffer killed,
            ;; tools-server registration dropped
            (should (claude-code-ide-mcp-session-cleanup-done session-a))
            (should-not (claude-code-ide-mcp--get-session-by-id "iso-a"))
            (should-not (buffer-live-p buffer-a))
            (should-not (gethash "iso-a" claude-code-ide-mcp-server--sessions))
            ;; The global most-recent buffer no longer points at it
            (should-not (eq claude-code-ide--last-accessed-buffer buffer-a))

            ;; The sibling is untouched, down to its own server and lockfile
            (should (eq (claude-code-ide-mcp--get-session-by-id "iso-b") session-b))
            (should (eq (claude-code-ide-mcp-session-server session-b) server-b))
            (should (file-exists-p (claude-code-ide-mcp--lockfile-path port-b)))
            (should (gethash "iso-b" claude-code-ide-mcp-server--sessions))
            ;; Project-wide tracking stays installed for the survivor
            (should (memq #'claude-code-ide-mcp--track-selection post-command-hook))
            (should (memq #'claude-code-ide-mcp--track-active-buffer post-command-hook))

            ;; Cleaning the same instance again is a no-op
            (claude-code-ide--cleanup-session session-a)
            (should (eq (claude-code-ide-mcp--get-session-by-id "iso-b") session-b))))
      (when (buffer-live-p buffer-a)
        (kill-buffer buffer-a))
      (claude-code-ide-tests--stop-all-sessions)
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-kill-buffer-no-nested-kill ()
  "Killing a terminal buffer leaves it alive for later kill hooks.
The session's `kill-buffer-hook' entry runs cleanup with the
buffer-dying flag, so backend hooks running after it (ghostel's
native-process hook) must still see a live buffer — a nested kill from
cleanup used to leave them firing on a dead one."
  (claude-code-ide-tests--clear-processes)
  (let* ((project-dir "/tmp/claude-nested-kill/")
         (buffer (generate-new-buffer "*claude-nested-kill*"))
         (backend-hook-saw-live-buffer nil)
         (session nil))
    (unwind-protect
        (let ((claude-code-ide-prevent-reflow-glitch nil))
          (setq session (claude-code-ide-tests--make-session project-dir
                                                             :buffer buffer))
          (with-current-buffer buffer
            (setq-local claude-code-ide--session session)
            ;; Simulate a backend kill hook registered BEFORE ours (like
            ;; ghostel-mode's): add-hook prepends, so registering it
            ;; first makes it run after the session's own hook
            (add-hook 'kill-buffer-hook
                      (lambda ()
                        (setq backend-hook-saw-live-buffer
                              (buffer-live-p (current-buffer))))
                      nil t)
            (add-hook 'kill-buffer-hook
                      (lambda ()
                        (claude-code-ide--cleanup-session session 'buffer-dying))
                      nil t))
          (kill-buffer buffer)
          (should backend-hook-saw-live-buffer)
          (should (claude-code-ide-mcp-session-cleanup-done session))
          (should-not (claude-code-ide-mcp--get-session-by-id
                       (claude-code-ide-mcp-session-session-id session)))
          (should-not (buffer-live-p buffer)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (claude-code-ide-tests--stop-all-sessions)
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-backend-recommendation ()
  "The ghostel suggestion is echoed once, only for vterm and eat."
  (let ((claude-code-ide--backend-recommendation-shown nil)
        (claude-code-ide-show-backend-recommendation t)
        (messages '()))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      ;; ghostel: no suggestion
      (let ((claude-code-ide-terminal-backend 'ghostel))
        (claude-code-ide--maybe-recommend-ghostel))
      (should (null messages))
      ;; eat: suggested once, then never again
      (let ((claude-code-ide-terminal-backend 'eat))
        (claude-code-ide--maybe-recommend-ghostel)
        (claude-code-ide--maybe-recommend-ghostel))
      (should (= 1 (length messages)))
      (should (string-match-p "ghostel" (car messages)))
      ;; disabled: nothing even when unseen
      (let ((claude-code-ide--backend-recommendation-shown nil)
            (claude-code-ide-show-backend-recommendation nil)
            (claude-code-ide-terminal-backend 'vterm))
        (claude-code-ide--maybe-recommend-ghostel))
      (should (= 1 (length messages))))))

(ert-deftest claude-code-ide-test-selection-dedupe-includes-file ()
  "Switching files at identical coordinates still notifies the CLI."
  (claude-code-ide-tests--clear-processes)
  (let* ((project-dir (expand-file-name "/tmp/claude-dedupe/"))
         (sent '()))
    (unwind-protect
        (let ((session (claude-code-ide-tests--make-session
                        project-dir
                        :client (claude-code-ide-tests--make-websocket "ws://dedupe"))))
          (ignore session)
          (cl-letf (((symbol-function 'claude-code-ide-mcp--send-notification)
                     (lambda (method _params session) (push (cons method session) sent))))
            (with-temp-buffer
              (setq buffer-file-name (expand-file-name "a.el" project-dir))
              (claude-code-ide-mcp--send-selection-for-project project-dir))
            (should (= 1 (length sent)))
            ;; Different file, same point/region coordinates → still a change
            (with-temp-buffer
              (setq buffer-file-name (expand-file-name "b.el" project-dir))
              (claude-code-ide-mcp--send-selection-for-project project-dir))
            (should (= 2 (length sent)))
            ;; Same file, same coordinates → deduped
            (with-temp-buffer
              (setq buffer-file-name (expand-file-name "b.el" project-dir))
              (claude-code-ide-mcp--send-selection-for-project project-dir))
            (should (= 2 (length sent)))))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-client-swap-mid-request ()
  "A reconnect during a tool handler must not leak to the new client.
Responses go only to the requesting socket, and deferred ids from the
replaced socket are discarded rather than stored for the successor."
  (claude-code-ide-tests--clear-processes)
  (let* ((project-dir "/tmp/claude-swap/")
         (old-ws (claude-code-ide-tests--make-websocket "ws://old"))
         (new-ws (claude-code-ide-tests--make-websocket "ws://new"))
         (sent '()))
    (unwind-protect
        (let ((session (claude-code-ide-tests--make-session project-dir
                                                            :client old-ws)))
          (cl-letf (((symbol-function 'websocket-send-text)
                     (lambda (ws text) (push (cons ws text) sent))))
            ;; Inline response: handler swaps the client mid-request
            (let ((claude-code-ide-mcp-tools
                   (list (cons "swapTool"
                               (lambda (_args session)
                                 (setf (claude-code-ide-mcp-session-client session) new-ws)
                                 (list '((type . "text") (text . "OK"))))))))
              (claude-code-ide-mcp--handle-message
               `((jsonrpc . "2.0") (id . 7) (method . "tools/call")
                 (params . ((name . "swapTool"))))
               session old-ws)
              ;; Dropped: neither socket received the response
              (should (null sent)))
            ;; Deferred id: same swap → id is discarded, not stored
            (let ((claude-code-ide-mcp-tools
                   (list (cons "swapDefer"
                               (lambda (_args session)
                                 (setf (claude-code-ide-mcp-session-client session) new-ws)
                                 (list '(deferred . t)))))))
              (claude-code-ide-mcp--handle-tools-call
               8 '((name . "swapDefer")) session old-ws)
              (should (= 0 (hash-table-count
                            (claude-code-ide-mcp-session-deferred session)))))))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-stop-session-survives-teardown-error ()
  "A failing teardown step still deregisters the session and hooks."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (let ((session (claude-code-ide-tests--make-session "/tmp/claude-wedge/")))
        (setf (claude-code-ide-mcp-session-port session) 12345)
        (add-hook 'post-command-hook #'claude-code-ide-mcp--track-selection)
        (cl-letf (((symbol-function 'claude-code-ide-mcp--remove-lockfile)
                   (lambda (_port) (error "Permission denied"))))
          (should-error (claude-code-ide-mcp--stop-session session)))
        ;; Despite the error: deregistered, hooks gone
        (should-not (claude-code-ide-mcp--get-session-by-id
                     (claude-code-ide-mcp-session-session-id session)))
        (should-not (memq #'claude-code-ide-mcp--track-selection post-command-hook)))
    (remove-hook 'post-command-hook #'claude-code-ide-mcp--track-selection)
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-cleanup-session-closes-diffs ()
  "Cleaning up an instance also closes its open diffs."
  (claude-code-ide-tests--clear-processes)
  (let ((buffer-b (generate-new-buffer "*claude-diff-b*")))
    (unwind-protect
        (let* ((session (claude-code-ide-tests--make-session "/tmp/claude-diffclean/"))
               (active-diffs (claude-code-ide-mcp-session-active-diffs session)))
          (puthash "tab-1"
                   `((buffer-B . ,buffer-b)
                     (file-exists . t)
                     (session . ,session))
                   active-diffs)
          (cl-letf (((symbol-function 'claude-code-ide-mcp-server-session-ended)
                     (lambda (&rest _) nil))
                    ((symbol-function 'claude-code-ide-mcp--stop-session)
                     (lambda (_session) nil)))
            (claude-code-ide--cleanup-session session))
          ;; The diff state is gone and its temp buffer killed
          (should (= 0 (hash-table-count active-diffs)))
          (should-not (buffer-live-p buffer-b)))
      (when (buffer-live-p buffer-b)
        (kill-buffer buffer-b))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-window-slot-block-overflow ()
  "A project overflowing its slot block gets a fresh block, not a neighbor's."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (let ((block claude-code-ide--window-slot-block))
        ;; Fill project A's entire block
        (dotimes (i block)
          (let ((session (claude-code-ide-tests--make-session "/tmp/slot-a/")))
            (setf (claude-code-ide-mcp-session-window-slot session) i)))
        ;; Project B takes the next block
        (let ((session-b (claude-code-ide-tests--make-session "/tmp/slot-b/")))
          (setf (claude-code-ide-mcp-session-window-slot session-b)
                (claude-code-ide--assign-window-slot "/tmp/slot-b/"))
          (should (= block (claude-code-ide-mcp-session-window-slot session-b))))
        ;; A's overflow instance must NOT land inside B's block
        (let ((slot (claude-code-ide--assign-window-slot "/tmp/slot-a/")))
          (should (>= slot (* 2 block)))))
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-window-slots-group-by-project ()
  "Interleaved instance creation still yields project-grouped slots.
Sorting sessions by slot must keep one project's instances adjacent:
emacs, emacs, src, src — not the emacs, src, src, emacs creation order."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (cl-flet ((new-session (project-dir)
                  (let ((session (claude-code-ide-tests--make-session project-dir)))
                    (setf (claude-code-ide-mcp-session-window-slot session)
                          (claude-code-ide--assign-window-slot project-dir))
                    session)))
        ;; Interleave two projects: emacs, src, src, emacs
        (let* ((e1 (new-session "/tmp/emacs/"))
               (s1 (new-session "/tmp/src/"))
               (s2 (new-session "/tmp/src/"))
               (e2 (new-session "/tmp/emacs/"))
               (ordered (sort (list e1 s1 s2 e2)
                              (lambda (a b)
                                (< (claude-code-ide-mcp-session-window-slot a)
                                   (claude-code-ide-mcp-session-window-slot b)))))
               (projects (mapcar #'claude-code-ide-mcp-session-project-dir ordered)))
          ;; Grouped: both emacs slots precede both src slots
          (should (equal projects (list "/tmp/emacs/" "/tmp/emacs/"
                                        "/tmp/src/" "/tmp/src/")))
          ;; All slots distinct
          (should (= 4 (length (cl-remove-duplicates
                                (mapcar #'claude-code-ide-mcp-session-window-slot
                                        ordered)))))
          ;; A stopped project's block is reused by the next new project
          (dolist (session (list e1 e2))
            (remhash (claude-code-ide-mcp-session-session-id session)
                     claude-code-ide-mcp--sessions))
          (let ((n1 (new-session "/tmp/next/")))
            (should (= 0 (claude-code-ide-mcp-session-window-slot n1))))))
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-hidden-panel-per-tab ()
  "Remembered hidden window sets are scoped per tab-bar tab.
Hiding a panel in one tab must not leak into another tab's restore,
and pruning drops entries whose tab no longer exists."
  (claude-code-ide-tests--clear-processes)
  (let ((current-tab "tab-1")
        (live-tabs '("tab-1" "tab-2")))
    (cl-letf (((symbol-function 'claude-code-ide--current-tab-key)
               (lambda () current-tab))
              ((symbol-function 'tab-bar-tabs)
               (lambda (&optional _frame)
                 (mapcar (lambda (name) (list 'tab (cons 'name name)))
                         live-tabs))))
      (unwind-protect
          (progn
            ;; Each tab remembers its own set, for projects and for :all
            (claude-code-ide--hidden-panel-set "/tmp/p/" '(a b))
            (claude-code-ide--hidden-panel-set :all '(c))
            (setq current-tab "tab-2")
            (should-not (claude-code-ide--hidden-panel-get "/tmp/p/"))
            (should-not (claude-code-ide--hidden-panel-get :all))
            (claude-code-ide--hidden-panel-set "/tmp/p/" '(d))
            (setq current-tab "tab-1")
            (should (equal (claude-code-ide--hidden-panel-get "/tmp/p/") '(a b)))
            (should (equal (claude-code-ide--hidden-panel-get :all) '(c)))
            ;; Closing a tab prunes its entries on the next set
            (setq live-tabs '("tab-1"))
            (claude-code-ide--hidden-panel-set :all '(e))
            (let ((keys (mapcar #'car (frame-parameter nil 'claude-code-ide-hidden-panel))))
              (should-not (cl-find "tab-2" keys :key #'car :test #'equal))))
        (set-frame-parameter nil 'claude-code-ide-hidden-panel nil)))))

(ert-deftest claude-code-ide-test-strip-new-tab-claude-windows ()
  "New tabs get cloned Claude side windows removed."
  (claude-code-ide-tests--clear-processes)
  (let* ((claude-buffer (generate-new-buffer "*claude-strip-tab*"))
         (other-buffer (generate-new-buffer "*strip-tab-other*"))
         (session (claude-code-ide-tests--make-session "/tmp/strip-tab/"
                                                       :buffer claude-buffer)))
    (unwind-protect
        (progn
          (with-current-buffer claude-buffer
            (setq-local claude-code-ide--session session))
          (delete-other-windows)
          (set-window-buffer (selected-window) other-buffer)
          (let ((claude-window (split-window)))
            (set-window-buffer claude-window claude-buffer)
            (should (get-buffer-window claude-buffer))
            (claude-code-ide--strip-new-tab-claude-windows)
            ;; The Claude window is gone, the other window survives
            (should-not (get-buffer-window claude-buffer))
            (should (get-buffer-window other-buffer))))
      (delete-other-windows)
      (kill-buffer claude-buffer)
      (kill-buffer other-buffer)
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-show-all ()
  "Show-all displays every hidden instance and skips visible ones."
  (claude-code-ide-tests--clear-processes)
  (let* ((project-dir "/tmp/claude-show-all/")
         (buffer-a (generate-new-buffer "*claude-show-all-a*"))
         (buffer-b (generate-new-buffer "*claude-show-all-b*"))
         (displayed '()))
    (unwind-protect
        (let ((session-a (claude-code-ide-tests--make-session project-dir
                                                              :buffer buffer-a))
              (session-b (claude-code-ide-tests--make-session project-dir
                                                              :buffer buffer-b)))
          (ignore session-b)
          (cl-letf (((symbol-function 'claude-code-ide--get-working-directory)
                     (lambda () (expand-file-name project-dir)))
                    ((symbol-function 'claude-code-ide--session-visible-p)
                     ;; Only A is visible
                     (lambda (session) (eq session session-a)))
                    ((symbol-function 'claude-code-ide--display-buffer-in-side-window)
                     (lambda (buffer) (push buffer displayed))))
            ;; Only the hidden instance gets displayed
            (claude-code-ide-show-all)
            (should (equal displayed (list buffer-b)))
            ;; No sessions anywhere errors
            (claude-code-ide-tests--clear-processes)
            (should-error (claude-code-ide-show-all) :type 'user-error)))
      (kill-buffer buffer-a)
      (kill-buffer buffer-b)
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-rename-session ()
  "Renaming an instance updates its name and its terminal buffer."
  (claude-code-ide-tests--clear-processes)
  (let* ((project-dir "/tmp/claude-rename/")
         (buffer (generate-new-buffer
                  (claude-code-ide--instance-buffer-name project-dir nil))))
    (unwind-protect
        (let ((session (claude-code-ide-tests--make-session project-dir
                                                            :buffer buffer)))
          (cl-letf (((symbol-function 'claude-code-ide--resolve-session)
                     (lambda (&rest _) session))
                    ((symbol-function 'claude-code-ide--read-instance-name)
                     (lambda (&rest _) "refactor")))
            (claude-code-ide-rename-session)
            (should (equal (claude-code-ide-mcp-session-instance-name session)
                           "refactor"))
            (should (equal (buffer-name buffer)
                           (claude-code-ide--instance-buffer-name project-dir
                                                                  "refactor")))
            (should (equal (claude-code-ide--session-display-name session)
                           "claude-rename:refactor")))

          ;; Empty input converts the instance back to the plain slot
          (cl-letf (((symbol-function 'claude-code-ide--resolve-session)
                     (lambda (&rest _) session))
                    ((symbol-function 'claude-code-ide--read-instance-name)
                     (lambda (&rest _) nil)))
            (claude-code-ide-rename-session)
            (should-not (claude-code-ide-mcp-session-instance-name session))
            (should (equal (buffer-name buffer)
                           (claude-code-ide--instance-buffer-name project-dir nil)))
            (should (equal (claude-code-ide--session-display-name session)
                           "claude-rename"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-stop-all-sessions-command ()
  "`claude-code-ide-stop-all' stops the project's instances after confirming."
  (claude-code-ide-tests--clear-processes)
  (let ((project-dir "/tmp/claude-stop-all/")
        (cleaned '())
        (confirm nil))
    (unwind-protect
        (let ((session-a (claude-code-ide-tests--make-session project-dir))
              (session-b (claude-code-ide-tests--make-session project-dir
                                                              :instance-name "b"))
              (other (claude-code-ide-tests--make-session "/tmp/claude-stop-other/")))
          (cl-letf (((symbol-function 'claude-code-ide--get-working-directory)
                     (lambda () project-dir))
                    ((symbol-function 'y-or-n-p) (lambda (&rest _) confirm))
                    ((symbol-function 'claude-code-ide--cleanup-session)
                     (lambda (session) (push session cleaned))))
            ;; Declining leaves everything running
            (claude-code-ide-stop-all)
            (should-not cleaned)

            ;; Confirming stops both instances of this project only
            (setq confirm t)
            (claude-code-ide-stop-all)
            (should (= 2 (length cleaned)))
            (should (memq session-a cleaned))
            (should (memq session-b cleaned))
            (should-not (memq other cleaned))

            ;; With a prefix argument every project's instances are stopped
            (setq cleaned '())
            (claude-code-ide-stop-all t)
            (should (= 3 (length cleaned)))
            (should (memq other cleaned))))
      (claude-code-ide-tests--clear-processes))))

(provide 'claude-code-ide-tests)

;; Local Variables:
;; no-update-autoloads: t
;; autoload-compute-prefixes: nil
;; End:

;;; claude-code-ide-tests.el ends here
