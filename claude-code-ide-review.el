;;; claude-code-ide-review.el --- Review view for edits made during a Claude session  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Keywords: ai, claude, mcp, tools, diff, review

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This file holds the data model behind the four-pane review view:
;; which edits exist since a Claude session started, and how they are
;; split into hunks.
;;
;; The review set is "working tree versus a baseline snapshot".  The
;; snapshot is a git commit object made when the first Claude session of
;; a project registers, or HEAD when the tree matched it.  It is built
;; through a temporary index file (`git add -A' with GIT_INDEX_FILE set,
;; then `git write-tree' and `git commit-tree'), so it holds untracked,
;; non-ignored files as well as tracked ones and never touches the real
;; index.  `git stash create' was rejected because it skips untracked
;; files, which would make a file the user wrote before the session look
;; like one large addition.  Git records content, not authorship, so
;; edits the user makes after the snapshot appear in the review as
;; well.  Snapshot commits are unreachable from any branch, and `git gc'
;; would prune them, so each one is pinned under
;; refs/claude-review/<session-id>.  Ending a Claude session keeps the
;; baseline and the notes, so a restarted session continues the same
;; review; `claude-code-ide-review-mark-baseline' starts a new one and
;; Emacs exit deletes the refs.  Nothing is persisted across Emacs
;; restarts in this version.
;;
;; Queries write nothing into the object store.  Tracked files are
;; compared with `git diff' against the snapshot commit.  Untracked
;; files are hashed with `git hash-object' (which stores nothing) and
;; compared with the snapshot tree; a changed one is diffed with
;; `git diff --no-index' against its snapshot content extracted to a
;; temporary file.  Untracked files above
;; `claude-code-ide-review-max-file-size' are left out of the snapshot
;; and of every query, and reported as skipped, so a directory of
;; simulation output that is not ignored cannot bloat .git or slow the
;; review down.  Hunks come from `git diff -U0', one call per file.  A
;; hunk's id is a hash of its file path and its removed and added text,
;; so later edits elsewhere in the file leave it unchanged.
;;
;; Non-git projects are not supported: the snapshot is skipped and the
;; query functions return nil.

;;; Code:

(require 'cl-lib)
(require 'filenotify)
(require 'json)
(require 'project)
(require 'server)
(require 'subr-x)
(require 'claude-code-ide-mcp-server)

;; The finish and explain commands talk to the Claude terminal; those
;; functions live in the main package, which is loaded whenever a
;; session exists for the commands to target
(declare-function claude-code-ide-send-prompt "claude-code-ide" (&optional prompt session))
(declare-function claude-code-ide--resolve-session "claude-code-ide" (intent &optional prompt))
(declare-function claude-code-ide-mcp-send-at-mentioned "claude-code-ide-mcp" (session))

(defgroup claude-code-ide-review nil
  "Review view for edits made during a Claude Code session."
  :group 'claude-code-ide
  :prefix "claude-code-ide-review-")

(defcustom claude-code-ide-review-auto-baseline t
  "When non-nil, snapshot the working tree when a Claude session starts.
The snapshot is the baseline that the review view diffs against.  With
nil, call `claude-code-ide-review-mark-baseline' before asking Claude
to work, or the review has nothing to compare with."
  :type 'boolean
  :group 'claude-code-ide-review)

(defcustom claude-code-ide-review-rebaseline-when-committed t
  "When non-nil, move the baseline to HEAD once every change is committed.
A git commit moves the branch but not the review baseline, so committed
edits would stay in the review.  With this option, a query that finds
HEAD moved since the baseline and the working tree equal to the new
HEAD moves the baseline there and clears the notes, since nothing is
left to review.  After a partial commit the review is left alone and
`review_open' reports that HEAD moved."
  :type 'boolean
  :group 'claude-code-ide-review)

(defcustom claude-code-ide-review-max-file-size (* 1024 1024)
  "Largest untracked file, in bytes, that takes part in the review.
Untracked files above this size are not copied into the baseline
snapshot and are not hashed by queries; `review_open' lists them as
skipped.  Tracked files are never subject to the limit, since git
already stores them.  Set to nil for no limit."
  :type '(choice (const :tag "No limit" nil)
                 (integer :tag "Bytes"))
  :group 'claude-code-ide-review)

(defcustom claude-code-ide-review-inline-limit 27000
  "Longest comment text, in characters, typed into the prompt in one piece.
`claude-code-ide-review-finish' types the formatted comments into the
Claude terminal when they fit; above the limit it sends a short prompt
asking Claude to read them with the `review_get_comments' tool instead.
The default is half the largest payload verified to arrive intact."
  :type 'integer
  :group 'claude-code-ide-review)

(defcustom claude-code-ide-review-sync-delay 0.5
  "Seconds of idle time after a change to the file shown before the panes rebuild.
The open review watches the directory of the file it shows; a change
to that file schedules a rebuild after this delay, so a burst of
writes causes one rebuild.  Set to nil to turn automatic rebuilds off
and rely on `claude-code-ide-review-refresh'."
  :type '(choice (const :tag "Off" nil)
                 (number :tag "Seconds"))
  :group 'claude-code-ide-review)

(defcustom claude-code-ide-review-explain-sends-prompt nil
  "When non-nil, `claude-code-ide-review-explain-hunk' also submits a request.
With nil only the hunk's file and line range are inserted into the
prompt, and the user types what to ask."
  :type 'boolean
  :group 'claude-code-ide-review)

(defcustom claude-code-ide-review-rules
  "Match the surrounding code style; state what changed and why in one or two sentences; name any behaviour change."
  "Rules Claude follows when it writes the justification for a hunk.
Sent in the `/emacs-tools:review' prompt unless that command is given
its own rules argument, and in the system prompt paragraph that
`claude-code-ide-review-annotate-on-edit' enables."
  :type 'string
  :group 'claude-code-ide-review)

(defcustom claude-code-ide-review-annotate-on-edit nil
  "When non-nil, ask Claude in its system prompt to annotate after every edit.
The paragraph tells Claude to call `review_annotate' after each Edit,
Write or MultiEdit call, following `claude-code-ide-review-rules'.  It
is read when a session's command line is built, so a change applies to
the next session.  Advisory only: hunks without a justification are
still shown as unexplained."
  :type 'boolean
  :group 'claude-code-ide-review)

(defcustom claude-code-ide-review-remind-on-edit nil
  "When non-nil, remind Claude of unexplained hunks after each of its edits.
A Claude Code PostToolUse hook, passed on the command line of new
sessions, asks Emacs through `emacsclient' which hunks of the edited
file lack a justification and shows the answer to Claude next to the
tool result.  Needs a running Emacs server (`server-start'); without
one the option has no effect.  Applies to the next session."
  :type 'boolean
  :group 'claude-code-ide-review)

;;; Data structures

(cl-defstruct claude-code-ide-review-baseline
  "Snapshot shared by the Claude sessions of one project."
  project-dir ; registered project directory, expanded, with trailing slash
  toplevel    ; git repository root, with trailing slash; git runs here
  commit      ; hash of the snapshot commit, or of HEAD for a clean tree
  ref         ; "refs/claude-review/<id>" pinning COMMIT, or nil for HEAD
  head        ; hash of HEAD when the snapshot was taken; nil without commits
  sessions)   ; session ids sharing this baseline

(cl-defstruct claude-code-ide-review-hunk
  "One changed region of a file, relative to the baseline."
  id          ; sha1 of (file, removed, added); unchanged by edits elsewhere
  file        ; path relative to the repository toplevel
  old-start   ; first line of the region in the baseline file (1-based)
  old-count   ; lines removed; 0 for a pure insertion
  new-start   ; first line of the region in the working file (1-based)
  new-count   ; lines added; 0 for a pure deletion
  removed     ; removed lines joined with newlines, no trailing newline
  added)      ; added lines joined with newlines, no trailing newline

(defvar claude-code-ide-review--baselines (make-hash-table :test 'equal)
  "Project directory -> `claude-code-ide-review-baseline'.")

(defvar claude-code-ide-review--notes) ; defined with the note functions below

;;; Git helper

(defun claude-code-ide-review--git (dir &rest args)
  "Run git with ARGS in DIR and return (EXIT-CODE . OUTPUT).
OUTPUT is stdout with surrounding whitespace removed; stderr is
discarded.  A fixed author identity is passed because `git stash
create' writes commit objects and fails in a repository that has no
user.name and user.email configured."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (cons (apply #'call-process "git" nil (list t nil) nil
                   "-c" "user.name=claude-code-ide"
                   "-c" "user.email=claude-code-ide@localhost"
                   args)
            (string-trim (buffer-string))))))

(defun claude-code-ide-review--git-ok (dir &rest args)
  "Run git with ARGS in DIR; return the trimmed output, or nil on failure."
  (let ((result (apply #'claude-code-ide-review--git dir args)))
    (when (eq (car result) 0)
      (cdr result))))

(defun claude-code-ide-review--normalize-dir (dir)
  "Return DIR expanded with a trailing slash, the key form for baselines."
  (file-name-as-directory (expand-file-name dir)))

;;; Baseline

(defun claude-code-ide-review--git-lines (dir &rest args)
  "Run git ARGS in DIR with -z style output and return the NUL-separated items.
Returns nil on failure or empty output."
  (when-let* ((output (apply #'claude-code-ide-review--git-ok dir args)))
    (split-string output "\0" t)))

(defun claude-code-ide-review--untracked-files (toplevel)
  "Return (KEPT . SKIPPED) untracked, non-ignored files under TOPLEVEL.
SKIPPED holds the files above `claude-code-ide-review-max-file-size';
KEPT the rest.  Paths are relative to TOPLEVEL."
  (let ((kept '())
        (skipped '()))
    (dolist (file (claude-code-ide-review--git-lines
                   toplevel "ls-files" "--others" "--exclude-standard" "-z"))
      (let ((size (file-attribute-size
                   (file-attributes (expand-file-name file toplevel)))))
        (if (and claude-code-ide-review-max-file-size
                 size
                 (> size claude-code-ide-review-max-file-size))
            (push file skipped)
          (push file kept))))
    (cons (nreverse kept) (nreverse skipped))))

(defun claude-code-ide-review--write-tree (toplevel)
  "Return the hash of a tree object holding the working tree at TOPLEVEL.
The tree holds HEAD's files with the working copy's edits and
deletions applied, plus the untracked, non-ignored files that are not
above `claude-code-ide-review-max-file-size'.  It is built in a
temporary index file so the repository's own index and staging state
are left alone.  This is the one place that writes blobs into the
object store.  Returns nil when git fails."
  (let ((index (make-temp-file "claude-review-index-"))
        (pathspec (make-temp-file "claude-review-paths-"))
        (head (claude-code-ide-review--git-ok toplevel "rev-parse" "--verify" "-q" "HEAD")))
    (unwind-protect
        (let ((process-environment
               (cons (concat "GIT_INDEX_FILE=" index) process-environment))
              (untracked (car (claude-code-ide-review--untracked-files toplevel))))
          (with-temp-file pathspec
            (insert (mapconcat #'identity untracked "\0")))
          ;; `make-temp-file' leaves an empty file, which git rejects as a
          ;; corrupt index; read-tree writes a valid one.  Without HEAD
          ;; every file is untracked and the pathspec covers them all.
          (and (if head
                   (and (claude-code-ide-review--git-ok toplevel "read-tree" head)
                        (claude-code-ide-review--git-ok toplevel "add" "-u" "."))
                 (claude-code-ide-review--git-ok toplevel "read-tree" "--empty"))
               (or (null untracked)
                   (claude-code-ide-review--git-ok
                    toplevel "add" "--pathspec-file-nul"
                    (concat "--pathspec-from-file=" pathspec)))
               (claude-code-ide-review--git-ok toplevel "write-tree")))
      (delete-file index)
      (delete-file pathspec))))

(defun claude-code-ide-review--snapshot-commit (toplevel session-id)
  "Create a snapshot of the working tree at TOPLEVEL.
Return (COMMIT REF HEAD).  HEAD is the current HEAD hash, nil in a
repository without commits.  When the working tree matches HEAD, COMMIT
is HEAD and REF is nil.  Otherwise COMMIT is a new commit object with
HEAD as parent (none without commits) and REF is the
refs/claude-review/SESSION-ID ref that pins it.  Return nil when git
fails."
  (when-let* ((tree (claude-code-ide-review--write-tree toplevel)))
    (let ((head (claude-code-ide-review--git-ok toplevel "rev-parse" "--verify" "-q" "HEAD"))
          (head-tree (claude-code-ide-review--git-ok toplevel "rev-parse" "--verify" "-q" "HEAD^{tree}")))
      (if (and head (equal tree head-tree))
          (list head nil head)
        (when-let* ((commit (apply #'claude-code-ide-review--git-ok toplevel
                                   "commit-tree" tree "-m" "claude-code-ide review baseline"
                                   (and head (list "-p" head))))
                    (ref (format "refs/claude-review/%s" session-id)))
          (when (claude-code-ide-review--git-ok toplevel "update-ref" ref commit)
            (list commit ref head)))))))

(defun claude-code-ide-review--snapshot (project-dir session-id)
  "Record a baseline for PROJECT-DIR owned by SESSION-ID.
If PROJECT-DIR already has a baseline, add SESSION-ID to it and keep
the existing commit, so a second session in the same project does not
move the baseline under the first.  Return the baseline, or nil when
PROJECT-DIR is not inside a git repository or has no commits."
  (let* ((dir (claude-code-ide-review--normalize-dir project-dir))
         (existing (gethash dir claude-code-ide-review--baselines)))
    (cond
     (existing
      (cl-pushnew session-id (claude-code-ide-review-baseline-sessions existing)
                  :test #'equal)
      existing)
     (t
      (when-let* ((toplevel (and (file-directory-p dir)
                                 (claude-code-ide-review--git-ok
                                  dir "rev-parse" "--show-toplevel")))
                  (toplevel (claude-code-ide-review--normalize-dir toplevel))
                  (snapshot (claude-code-ide-review--snapshot-commit toplevel session-id)))
        (puthash dir
                 (make-claude-code-ide-review-baseline
                  :project-dir dir
                  :toplevel toplevel
                  :commit (nth 0 snapshot)
                  :ref (nth 1 snapshot)
                  :head (nth 2 snapshot)
                  :sessions (list session-id))
                 claude-code-ide-review--baselines))))))

(defun claude-code-ide-review--delete-ref (baseline)
  "Delete the pinning ref of BASELINE, if it has one."
  (when-let* ((ref (claude-code-ide-review-baseline-ref baseline)))
    (claude-code-ide-review--git (claude-code-ide-review-baseline-toplevel baseline)
                                 "update-ref" "-d" ref)
    (setf (claude-code-ide-review-baseline-ref baseline) nil)))

(defun claude-code-ide-review--baseline-for-session (session-id)
  "Return the baseline that lists SESSION-ID, or nil."
  (catch 'found
    (maphash (lambda (_dir baseline)
               (when (member session-id (claude-code-ide-review-baseline-sessions baseline))
                 (throw 'found baseline)))
             claude-code-ide-review--baselines)
    nil))

(defun claude-code-ide-review--release (session-id)
  "Drop SESSION-ID from its baseline.
The baseline and the project's notes stay, even when no session shares
them any more, so a Claude session restarted with --continue or
--resume reviews against the same baseline and keeps its
justifications.  They go away when `claude-code-ide-review-mark-baseline'
starts a new review or when Emacs exits.  Unknown ids are ignored."
  (when-let* ((baseline (claude-code-ide-review--baseline-for-session session-id)))
    (setf (claude-code-ide-review-baseline-sessions baseline)
          (delete session-id (claude-code-ide-review-baseline-sessions baseline)))))

(defun claude-code-ide-review--release-all ()
  "Delete every pinning ref and forget all baselines and notes.
Runs from `kill-emacs-hook'.  A ref that survives an Emacs crash is
harmless: it only keeps one snapshot commit alive, and the next
`claude-code-ide-review-mark-baseline' in that project replaces it."
  (maphash (lambda (_dir baseline)
             (claude-code-ide-review--delete-ref baseline))
           claude-code-ide-review--baselines)
  (clrhash claude-code-ide-review--baselines)
  (clrhash claude-code-ide-review--notes))

(defun claude-code-ide-review--current-head (baseline)
  "Return the repository's current HEAD hash for BASELINE, or nil."
  (claude-code-ide-review--git-ok (claude-code-ide-review-baseline-toplevel baseline)
                                  "rev-parse" "--verify" "-q" "HEAD"))

(defun claude-code-ide-review-head-moved-p (project-dir)
  "Return non-nil when HEAD has moved since PROJECT-DIR's baseline was taken.
Nil without a baseline."
  (when-let* ((baseline (gethash (claude-code-ide-review--normalize-dir project-dir)
                                 claude-code-ide-review--baselines)))
    (not (equal (claude-code-ide-review-baseline-head baseline)
                (claude-code-ide-review--current-head baseline)))))

(defun claude-code-ide-review--clean-tree-p (toplevel)
  "Return non-nil when the working tree at TOPLEVEL has nothing to review.
That is: tracked files equal HEAD and no untracked file under the size
limit exists.  Untracked files above the limit are ignored here as
everywhere else in the review."
  (and (eq 0 (car (claude-code-ide-review--git toplevel "diff" "--quiet" "HEAD")))
       (null (car (claude-code-ide-review--untracked-files toplevel)))))

(defun claude-code-ide-review--sync-with-head (baseline)
  "Move BASELINE to HEAD when every change has been committed.
Does nothing unless `claude-code-ide-review-rebaseline-when-committed'
is set, HEAD differs from the one BASELINE was taken against, the
working tree is clean, and no user comment is still unsent (see
`claude-code-ide-review-unsent-comments'); a commit must not discard
comments the user has not sent.  Returns the baseline now in force."
  (let ((dir (claude-code-ide-review-baseline-project-dir baseline))
        (toplevel (claude-code-ide-review-baseline-toplevel baseline)))
    (if (and claude-code-ide-review-rebaseline-when-committed
             (not (equal (claude-code-ide-review-baseline-head baseline)
                         (claude-code-ide-review--current-head baseline)))
             (null (claude-code-ide-review-unsent-comments dir))
             (claude-code-ide-review--clean-tree-p toplevel))
        (or (claude-code-ide-review-mark-baseline dir) baseline)
      baseline)))

(defun claude-code-ide-review-baseline (project-dir)
  "Return the baseline in force for PROJECT-DIR, or nil.
Moves the baseline first when all changes were committed; see
`claude-code-ide-review-rebaseline-when-committed'."
  (when-let* ((baseline (gethash (claude-code-ide-review--normalize-dir project-dir)
                                 claude-code-ide-review--baselines)))
    (claude-code-ide-review--sync-with-head baseline)))

(defun claude-code-ide-review--project-dir ()
  "Return the project directory the current command or tool call refers to.
Inside an MCP tool call this is the session's registered project.
Interactively it is the current `project' root, else `default-directory'."
  (or (plist-get (claude-code-ide-mcp-server-get-session-context) :project-dir)
      (when-let* ((project (project-current nil)))
        (project-root project))
      default-directory))

(defun claude-code-ide-review--on-session-started (session-id project-dir)
  "Snapshot PROJECT-DIR for SESSION-ID when auto-baseline is enabled."
  (when claude-code-ide-review-auto-baseline
    (claude-code-ide-review--snapshot project-dir session-id)))

;;;###autoload
(defun claude-code-ide-review-mark-baseline (&optional project-dir)
  "Make the current working tree the review baseline for PROJECT-DIR.
Edits made before this point disappear from the review; edits made
after it appear.  PROJECT-DIR defaults to the directory
`claude-code-ide-review--project-dir' returns.  Sessions already
sharing the old baseline move to the new one.  Returns the new
baseline, or nil for a directory outside a git repository."
  (interactive)
  (let* ((dir (claude-code-ide-review--normalize-dir
               (or project-dir (claude-code-ide-review--project-dir))))
         (old (gethash dir claude-code-ide-review--baselines))
         (sessions (and old (claude-code-ide-review-baseline-sessions old)))
         (owner (or (car sessions)
                    (format "manual-%s" (format-time-string "%Y%m%d-%H%M%S")))))
    (when old
      (claude-code-ide-review--delete-ref old)
      (remhash dir claude-code-ide-review--baselines))
    ;; Every hunk id changes with the baseline, so existing notes could
    ;; never match again; a moved baseline starts a new review
    (claude-code-ide-review--clear-notes dir)
    (let ((new (claude-code-ide-review--snapshot dir owner)))
      (cond
       ((null new)
        (when (called-interactively-p 'interactive)
          (message "No git repository at %s; no baseline recorded" dir))
        nil)
       (t
        (dolist (id (cdr sessions))
          (cl-pushnew id (claude-code-ide-review-baseline-sessions new) :test #'equal))
        (when (called-interactively-p 'interactive)
          (message "Review baseline set to %s"
                   (substring (claude-code-ide-review-baseline-commit new) 0 12)))
        new)))))

;;; Changed files

(defun claude-code-ide-review--baseline-blobs (baseline)
  "Return a hash table of path -> blob hash for every file in BASELINE."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (entry (claude-code-ide-review--git-lines
                    (claude-code-ide-review-baseline-toplevel baseline)
                    "ls-tree" "-r" "-z" (claude-code-ide-review-baseline-commit baseline)))
      ;; "<mode> blob <hash>\t<path>"
      (when (string-match "\\`[0-7]+ blob \\([0-9a-f]+\\)\t\\(.*\\)\\'" entry)
        (puthash (match-string 2 entry) (match-string 1 entry) table)))
    table))

(defun claude-code-ide-review--hash-files (toplevel files)
  "Return the blob hashes of FILES under TOPLEVEL, in order, storing nothing.
Uses `git hash-object --stdin-paths', which computes the hash a blob
would have without writing it to the object store."
  (when files
    (with-temp-buffer
      (let ((default-directory toplevel))
        (insert (mapconcat #'identity files "\n") "\n")
        (when (eq 0 (call-process-region (point-min) (point-max) "git" t t nil
                                         "hash-object" "--stdin-paths"))
          (split-string (buffer-string) "\n" t))))))

(defun claude-code-ide-review--tracked-p (toplevel file)
  "Return non-nil when FILE is in the repository's index at TOPLEVEL."
  (claude-code-ide-review--git-lines toplevel "ls-files" "-z" "--" file))

(defun claude-code-ide-review-skipped-files (project-dir)
  "Return the untracked files of PROJECT-DIR left out for exceeding the size limit."
  (when-let* ((baseline (claude-code-ide-review-baseline project-dir)))
    (cdr (claude-code-ide-review--untracked-files
          (claude-code-ide-review-baseline-toplevel baseline)))))

(defun claude-code-ide-review-changed-files (project-dir)
  "Return the files of PROJECT-DIR that differ from its baseline.
Paths are relative to the repository toplevel, sorted.  Files that are
new, edited or deleted since the snapshot are all listed, whether
tracked or untracked; ignored files and untracked files above
`claude-code-ide-review-max-file-size' never are.  Nothing is written
to the object store.  Returns nil when PROJECT-DIR has no baseline."
  (when-let* ((baseline (claude-code-ide-review-baseline project-dir)))
    (let* ((toplevel (claude-code-ide-review-baseline-toplevel baseline))
           (commit (claude-code-ide-review-baseline-commit baseline))
           (blobs (claude-code-ide-review--baseline-blobs baseline))
           (tracked (make-hash-table :test 'equal))
           (untracked (car (claude-code-ide-review--untracked-files toplevel)))
           (hashes (claude-code-ide-review--hash-files toplevel untracked))
           (changed '()))
      (dolist (file (claude-code-ide-review--git-lines toplevel "ls-files" "-z"))
        (puthash file t tracked))
      ;; Tracked files.  `git diff <commit>' compares the commit with the
      ;; index-tracked working tree, so it also reports snapshot files that
      ;; are untracked in the real index as deleted; keep index entries only
      ;; and let the hash comparison below judge the untracked ones.
      (dolist (file (claude-code-ide-review--git-lines
                     toplevel "diff" "--name-only" "-z" commit))
        (when (gethash file tracked)
          (push file changed)))
      ;; Untracked files: new, or different from their snapshot blob
      (cl-loop for file in untracked
               for hash in hashes
               unless (equal hash (gethash file blobs))
               do (push file changed))
      ;; Files in the snapshot that are neither tracked nor on disk: deleted
      ;; untracked files
      (maphash (lambda (file _hash)
                 (unless (or (gethash file tracked)
                             (file-exists-p (expand-file-name file toplevel)))
                   (push file changed)))
               blobs)
      (sort (delete-dups changed) #'string<))))

;;; Hunks

(defconst claude-code-ide-review--hunk-header-regexp
  "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
  "Unified diff hunk header.  Groups: old start, old count, new start, new count.
A missing count means 1, as in `@@ -2 +2 @@'.")

(defun claude-code-ide-review--hunk-id (file removed added)
  "Return the id of a hunk in FILE with REMOVED and ADDED text."
  (secure-hash 'sha1 (concat file "\0" removed "\0" added)))

(defun claude-code-ide-review--parse-hunks (file diff-text)
  "Parse unified DIFF-TEXT for FILE into `claude-code-ide-review-hunk' objects.
Everything before the first hunk header (the `diff --git', `---' and
`+++' lines) is skipped.  Inside a hunk, lines beginning with `-' or
`+' are removed or added text; the `\\ No newline at end of file'
marker is ignored."
  (let ((hunks '())
        (current nil)
        (removed nil)
        (added nil))
    (cl-flet ((finish ()
                (when current
                  (let ((removed-text (string-join (nreverse removed) "\n"))
                        (added-text (string-join (nreverse added) "\n")))
                    (setf (claude-code-ide-review-hunk-removed current) removed-text
                          (claude-code-ide-review-hunk-added current) added-text
                          (claude-code-ide-review-hunk-id current)
                          (claude-code-ide-review--hunk-id file removed-text added-text))
                    (push current hunks)))
                (setq current nil removed nil added nil)))
      (dolist (line (split-string diff-text "\n"))
        (cond
         ((string-match claude-code-ide-review--hunk-header-regexp line)
          (finish)
          (setq current (make-claude-code-ide-review-hunk
                         :file file
                         :old-start (string-to-number (match-string 1 line))
                         :old-count (if (match-string 2 line)
                                        (string-to-number (match-string 2 line))
                                      1)
                         :new-start (string-to-number (match-string 3 line))
                         :new-count (if (match-string 4 line)
                                        (string-to-number (match-string 4 line))
                                      1))))
         ((null current) nil)
         ((string-prefix-p "\\" line) nil)
         ((string-prefix-p "-" line) (push (substring line 1) removed))
         ((string-prefix-p "+" line) (push (substring line 1) added))))
      (finish))
    (nreverse hunks)))

(defun claude-code-ide-review--with-baseline-copy (baseline file function)
  "Call FUNCTION with a temporary file holding FILE's content in BASELINE.
The argument is \"/dev/null\" when FILE is not in the snapshot.  The
temporary file is removed afterwards.  Content is copied byte for
byte so binary and non-UTF-8 files survive the round trip."
  (let* ((toplevel (claude-code-ide-review-baseline-toplevel baseline))
         (in-baseline (eq 0 (car (claude-code-ide-review--git
                                  toplevel "cat-file" "-e"
                                  (format "%s:%s" (claude-code-ide-review-baseline-commit baseline)
                                          file)))))
         (copy (and in-baseline (make-temp-file "claude-review-base-"))))
    (unwind-protect
        (progn
          (when copy
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (let ((default-directory toplevel)
                    (coding-system-for-read 'no-conversion)
                    (coding-system-for-write 'no-conversion))
                (call-process "git" nil (list t nil) nil "show"
                              (format "%s:%s" (claude-code-ide-review-baseline-commit baseline)
                                      file))
                (write-region (point-min) (point-max) copy nil 'silent))))
          (funcall function (or copy "/dev/null")))
      (when copy
        (delete-file copy)))))

(defun claude-code-ide-review-hunks (project-dir file)
  "Return the hunks of FILE in PROJECT-DIR relative to its baseline, in file order.
FILE is relative to the repository toplevel, as returned by
`claude-code-ide-review-changed-files'.  A file created after the
snapshot yields one fully-added hunk; a deleted file one fully-removed
hunk.  Nothing is written to the object store.  Returns nil without a
baseline, and nil for an unchanged file."
  (when-let* ((baseline (claude-code-ide-review-baseline project-dir)))
    (let* ((toplevel (claude-code-ide-review-baseline-toplevel baseline))
           (commit (claude-code-ide-review-baseline-commit baseline))
           (result
            (if (claude-code-ide-review--tracked-p toplevel file)
                (claude-code-ide-review--git toplevel "diff" "-U0" commit "--" file)
              ;; Untracked: compare the snapshot copy with the working file;
              ;; --no-index exits 1 when they differ, which is not an error
              (claude-code-ide-review--with-baseline-copy
               baseline file
               (lambda (copy)
                 (let ((working (expand-file-name file toplevel)))
                   (claude-code-ide-review--git
                    toplevel "diff" "--no-index" "-U0" copy
                    (if (file-exists-p working) working "/dev/null"))))))))
      (when (memq (car result) '(0 1))
        (claude-code-ide-review--parse-hunks file (cdr result))))))

(defun claude-code-ide-review-all-hunks (project-dir)
  "Return the hunks of every changed file in PROJECT-DIR, file by file."
  (mapcan (lambda (file) (claude-code-ide-review-hunks project-dir file))
          (claude-code-ide-review-changed-files project-dir)))

;;; Notes

(cl-defstruct claude-code-ide-review-note
  "A justification by Claude or a review comment by the user for one hunk."
  hunk-id     ; id of the hunk the note was written for
  file        ; the hunk's file, relative to the repository toplevel
  text        ; note body
  kind        ; `claude' for a justification, `user' for a review comment
  new-start   ; the hunk's working-file range when the note was written;
  new-count   ;   used to match the note to a hunk whose text changed
  created     ; `current-time' at creation
  sent)       ; non-nil once a `user' note was sent to the prompt

(defvar claude-code-ide-review--notes (make-hash-table :test 'equal)
  "Project directory -> table of (KIND . HUNK-ID) -> `claude-code-ide-review-note'.
One note per hunk and kind.  Cleared when the project's baseline moves,
because every hunk id changes with the baseline and a new baseline is a
new review, and when Emacs exits.")

(defun claude-code-ide-review--note-table (project-dir &optional create)
  "Return PROJECT-DIR's note table.
With CREATE non-nil make an empty one when none exists; otherwise
return nil in that case."
  (let ((dir (claude-code-ide-review--normalize-dir project-dir)))
    (or (gethash dir claude-code-ide-review--notes)
        (and create
             (puthash dir (make-hash-table :test 'equal) claude-code-ide-review--notes)))))

(defun claude-code-ide-review--clear-notes (project-dir)
  "Forget every note of PROJECT-DIR."
  (remhash (claude-code-ide-review--normalize-dir project-dir)
           claude-code-ide-review--notes))

(defun claude-code-ide-review-put-note (project-dir hunk kind text)
  "Store TEXT as the KIND note of HUNK in PROJECT-DIR and return the note.
KIND is `claude' or `user'.  An existing note for the same hunk and
kind is replaced; the other kind's note is left alone."
  (let ((note (make-claude-code-ide-review-note
               :hunk-id (claude-code-ide-review-hunk-id hunk)
               :file (claude-code-ide-review-hunk-file hunk)
               :text text
               :kind kind
               :new-start (claude-code-ide-review-hunk-new-start hunk)
               :new-count (claude-code-ide-review-hunk-new-count hunk)
               :created (current-time))))
    (puthash (cons kind (claude-code-ide-review-hunk-id hunk))
             note
             (claude-code-ide-review--note-table project-dir t))
    note))

(defun claude-code-ide-review-unsent-comments (project-dir)
  "Return the `user' notes of PROJECT-DIR that were never sent to the prompt.
While any exist, the review must not be reset by anything but the user:
`claude-code-ide-review-tool-mark-baseline' refuses and the automatic
move to HEAD after a commit waits.  Blank comments do not count."
  (let ((unsent '()))
    (when-let* ((table (claude-code-ide-review--note-table project-dir)))
      (maphash (lambda (key note)
                 (when (and (eq (car key) 'user)
                            (not (claude-code-ide-review-note-sent note))
                            (not (string-blank-p (claude-code-ide-review-note-text note))))
                   (push note unsent)))
               table))
    unsent))

(defun claude-code-ide-review-remove-note (project-dir hunk-id kind)
  "Forget the KIND note of HUNK-ID in PROJECT-DIR, if any."
  (when-let* ((table (claude-code-ide-review--note-table project-dir)))
    (remhash (cons kind hunk-id) table)))

(defun claude-code-ide-review-get-note (project-dir hunk-id kind)
  "Return the KIND note stored for HUNK-ID in PROJECT-DIR, or nil."
  (when-let* ((table (claude-code-ide-review--note-table project-dir)))
    (gethash (cons kind hunk-id) table)))

(defun claude-code-ide-review-notes (project-dir &optional kind)
  "Return the notes of PROJECT-DIR, those of KIND when it is given.
Sorted by file, then by the line range recorded when the note was
written, so callers that print them walk the project in file order."
  (let ((notes '()))
    (when-let* ((table (claude-code-ide-review--note-table project-dir)))
      (maphash (lambda (key note)
                 (when (or (null kind) (eq (car key) kind))
                   (push note notes)))
               table))
    (sort notes
          (lambda (a b)
            (let ((file-a (claude-code-ide-review-note-file a))
                  (file-b (claude-code-ide-review-note-file b)))
              (or (string< file-a file-b)
                  (and (string= file-a file-b)
                       (< (claude-code-ide-review-note-new-start a)
                          (claude-code-ide-review-note-new-start b)))))))))

;;; Matching hunks to line ranges and notes

(defun claude-code-ide-review--range-end (start count)
  "Last line of a range of COUNT lines starting at START.
A range with COUNT 0, a pure deletion, still occupies the one line
START so it can be pointed at."
  (+ start (max count 1) -1))

(defun claude-code-ide-review--overlap (a-start a-end b-start b-end)
  "Number of lines shared by A-START..A-END and B-START..B-END, 0 if none."
  (max 0 (1+ (- (min a-end b-end) (max a-start b-start)))))

(defun claude-code-ide-review--hunk-overlap (hunk start end)
  "Number of working-file lines HUNK shares with START..END."
  (let ((hunk-start (claude-code-ide-review-hunk-new-start hunk)))
    (claude-code-ide-review--overlap
     hunk-start
     (claude-code-ide-review--range-end hunk-start (claude-code-ide-review-hunk-new-count hunk))
     start end)))

(defun claude-code-ide-review-hunk-at (project-dir file start end)
  "Return the hunk of FILE in PROJECT-DIR that overlaps lines START..END.
Lines are 1-based positions in the working file.  When several hunks
overlap, return the one sharing the most lines.  Return nil when no
hunk overlaps."
  (let ((best nil)
        (best-overlap 0))
    (dolist (hunk (claude-code-ide-review-hunks project-dir file))
      (let ((overlap (claude-code-ide-review--hunk-overlap hunk start end)))
        (when (> overlap best-overlap)
          (setq best hunk
                best-overlap overlap))))
    best))

(defun claude-code-ide-review--stale-note (table hunk kind live-ids)
  "Return a KIND note in TABLE that lost its hunk but overlaps HUNK, or nil.
A note has lost its hunk when its id is not in LIVE-IDS, the ids of
the file's current hunks.  Among several candidates the one sharing the
most lines with HUNK wins."
  (let ((file (claude-code-ide-review-hunk-file hunk))
        (hunk-start (claude-code-ide-review-hunk-new-start hunk))
        (best nil)
        (best-overlap 0))
    (maphash
     (lambda (key note)
       (when (and (eq (car key) kind)
                  (string= (claude-code-ide-review-note-file note) file)
                  (not (member (cdr key) live-ids)))
         (let* ((note-start (claude-code-ide-review-note-new-start note))
                (overlap (claude-code-ide-review--overlap
                          hunk-start
                          (claude-code-ide-review--range-end
                           hunk-start (claude-code-ide-review-hunk-new-count hunk))
                          note-start
                          (claude-code-ide-review--range-end
                           note-start (claude-code-ide-review-note-new-count note)))))
           (when (> overlap best-overlap)
             (setq best note
                   best-overlap overlap)))))
     table)
    best))

(defun claude-code-ide-review-hunk-status (project-dir hunk kind &optional live-hunks)
  "Return (STATUS . NOTE) for HUNK and KIND in PROJECT-DIR.
STATUS is `ok' when a KIND note exists under the hunk's id, `stale'
when a KIND note for the same file no longer matches any current hunk
but its recorded range overlaps HUNK, and `unexplained' otherwise.
NOTE is the matching note, nil for `unexplained'.  LIVE-HUNKS, the
current hunks of the file, avoids recomputing them for every hunk;
when nil they are computed here."
  (let ((table (claude-code-ide-review--note-table project-dir)))
    (if (null table)
        (cons 'unexplained nil)
      (if-let* ((note (gethash (cons kind (claude-code-ide-review-hunk-id hunk)) table)))
          (cons 'ok note)
        (let ((live-ids (mapcar #'claude-code-ide-review-hunk-id
                                (or live-hunks
                                    (claude-code-ide-review-hunks
                                     project-dir (claude-code-ide-review-hunk-file hunk))))))
          (if-let* ((stale (claude-code-ide-review--stale-note table hunk kind live-ids)))
              (cons 'stale stale)
            (cons 'unexplained nil)))))))

(defun claude-code-ide-review-file-statuses (project-dir file &optional kind)
  "Return (HUNK STATUS NOTE) for each hunk of FILE in PROJECT-DIR.
Entries are in file order.  KIND defaults to `claude'.  The file's
hunks are computed once."
  (let* ((kind (or kind 'claude))
         (hunks (claude-code-ide-review-hunks project-dir file)))
    (mapcar (lambda (hunk)
              (let ((status (claude-code-ide-review-hunk-status project-dir hunk kind hunks)))
                (list hunk (car status) (cdr status))))
            hunks)))

;;; Pane contents

(defcustom claude-code-ide-review-context-lines 3
  "Unchanged lines shown on each side of a hunk in the diff panes.
A longer unchanged span is folded to this many lines next to each
neighbouring hunk with a marker row in between.  nil shows every line."
  :type '(choice (const :tag "Show every line" nil)
                 (integer :tag "Lines"))
  :group 'claude-code-ide-review)

(defface claude-code-ide-review-removed
  '((t :inherit diff-removed))
  "Face for lines removed since the baseline (pane 0)."
  :group 'claude-code-ide-review)

(defface claude-code-ide-review-added
  '((t :inherit diff-added))
  "Face for lines added since the baseline (pane 1)."
  :group 'claude-code-ide-review)

(defface claude-code-ide-review-padding
  '((t :inherit shadow))
  "Face for padding rows that keep the four panes aligned."
  :group 'claude-code-ide-review)

(defface claude-code-ide-review-fold
  '((t :inherit shadow :slant italic))
  "Face for the marker row standing in for folded unchanged lines."
  :group 'claude-code-ide-review)

(defface claude-code-ide-review-header
  '((t :inherit bold))
  "Face for the header row of a hunk block in the comment panes."
  :group 'claude-code-ide-review)

(defface claude-code-ide-review-placeholder
  '((t :inherit font-lock-comment-face))
  "Face for the placeholder shown when Claude left no justification."
  :group 'claude-code-ide-review)

(defface claude-code-ide-review-line-number
  '((t :inherit line-number))
  "Face for the original line number shown before diff rows."
  :group 'claude-code-ide-review)

(defun claude-code-ide-review--read-file (path)
  "Return the text of PATH decoded as `insert-file-contents' would, or \"\"."
  (if (file-exists-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string))
    ""))

(defun claude-code-ide-review-baseline-content (project-dir file)
  "Return FILE's text in PROJECT-DIR's snapshot, \"\" when it is not there."
  (if-let* ((baseline (claude-code-ide-review-baseline project-dir)))
      (claude-code-ide-review--with-baseline-copy
       baseline file
       (lambda (copy)
         (if (equal copy "/dev/null")
             ""
           (claude-code-ide-review--read-file copy))))
    ""))

(defun claude-code-ide-review-working-content (project-dir file)
  "Return FILE's text on disk in PROJECT-DIR, \"\" for a deleted file.
Unsaved edits in a buffer visiting FILE are not included, so the text
agrees with the hunks git computed from disk."
  (if-let* ((baseline (claude-code-ide-review-baseline project-dir)))
      (claude-code-ide-review--read-file
       (expand-file-name file (claude-code-ide-review-baseline-toplevel baseline)))
    ""))

(defun claude-code-ide-review--text-lines (text)
  "Split TEXT into lines without a phantom empty line after a final newline."
  (if (string-empty-p text)
      nil
    (let ((lines (split-string text "\n")))
      (if (string-empty-p (car (last lines)))
          (butlast lines)
        lines))))

;;; Row model

(cl-defstruct claude-code-ide-review-row
  "One screen line of a review pane, before it is written to a buffer."
  text  ; the line, without newline
  kind  ; context, removed, added, padding, fold, header, note or placeholder
  hunk  ; 0-based index of the hunk the row belongs to, nil in an unchanged span
  line) ; original line number in the baseline (pane 0) or working file (pane 1)

(defun claude-code-ide-review--padding-rows (count hunk)
  "Return COUNT padding rows belonging to HUNK (an index or nil)."
  (let ((rows '()))
    (dotimes (_ count)
      (push (make-claude-code-ide-review-row :text "" :kind 'padding :hunk hunk) rows))
    rows))

(defun claude-code-ide-review--context-rows (lines first-line hunk-before hunk-after)
  "Return rows for the unchanged LINES, numbered from FIRST-LINE.
HUNK-BEFORE and HUNK-AFTER say whether a hunk borders the span on that
side; `claude-code-ide-review-context-lines' lines are kept next to each
bordering hunk and the rest is replaced by one fold row."
  (let* ((n claude-code-ide-review-context-lines)
         (total (length lines))
         (keep-head (if hunk-before (or n total) (and n 0)))
         (keep-tail (if hunk-after (or n total) (and n 0)))
         (row (lambda (text index)
                (make-claude-code-ide-review-row
                 :text text :kind 'context :line (+ first-line index)))))
    (if (or (null n)
            (<= total (+ (or keep-head 0) (or keep-tail 0) 1)))
        (cl-loop for text in lines
                 for index from 0
                 collect (funcall row text index))
      (let ((head (seq-take lines keep-head))
            (tail (last lines keep-tail))
            (folded (- total keep-head keep-tail)))
        (append
         (cl-loop for text in head for index from 0 collect (funcall row text index))
         (list (make-claude-code-ide-review-row
                :text (format "⋯ %d unchanged line%s ⋯" folded (if (= folded 1) "" "s"))
                :kind 'fold))
         (cl-loop for text in tail
                  for index from (- total keep-tail)
                  collect (funcall row text index)))))))

(defun claude-code-ide-review--placeholder-rows (hunk-index)
  "Return the rows telling the user that hunk HUNK-INDEX has no justification.
The key name follows the current binding of
`claude-code-ide-review-explain-hunk'."
  (let ((text (substitute-command-keys
               "Claude did not leave a comment. This change may have been made by you. If Claude made it, press \\[claude-code-ide-review-explain-hunk] here to send this hunk to the Claude prompt, then ask it to explain the change.")))
    (mapcar (lambda (line)
              (make-claude-code-ide-review-row :text line :kind 'placeholder :hunk hunk-index))
            (with-temp-buffer
              (insert text)
              (let ((fill-column 60))
                (fill-region (point-min) (point-max)))
              (claude-code-ide-review--text-lines (buffer-string))))))

(defun claude-code-ide-review--note-rows (hunk-index text kind)
  "Return rows of KIND for the note TEXT of hunk HUNK-INDEX; one empty row for nil."
  (mapcar (lambda (line)
            (make-claude-code-ide-review-row :text line :kind kind :hunk hunk-index))
          (or (and text (claude-code-ide-review--text-lines text)) (list ""))))

(defun claude-code-ide-review--block-rows (hunk-index hunk status note kind)
  "Return the comment-pane rows for HUNK: a header, then the note or placeholder.
STATUS and NOTE come from `claude-code-ide-review-hunk-status' for KIND,
`claude' for pane 2 or `user' for pane 3."
  (cons (make-claude-code-ide-review-row
         :text (format "#%d %s%s"
                       (1+ hunk-index)
                       (claude-code-ide-review--hunk-range-string hunk)
                       (if (eq status 'stale) " (stale)" ""))
         :kind 'header :hunk hunk-index)
        (cond
         ((and (eq kind 'claude) (eq status 'unexplained))
          (claude-code-ide-review--placeholder-rows hunk-index))
         (t
          (claude-code-ide-review--note-rows
           hunk-index (and note (claude-code-ide-review-note-text note)) 'note)))))

(defun claude-code-ide-review--diff-rows (text kind first-line hunk-index)
  "Return rows of KIND for the lines of TEXT, numbered from FIRST-LINE."
  (cl-loop for line in (claude-code-ide-review--text-lines text)
           for index from 0
           collect (make-claude-code-ide-review-row
                    :text line :kind kind :hunk hunk-index :line (+ first-line index))))

(defun claude-code-ide-review--pad-segment (panes hunk-index)
  "Pad the four row lists in PANES to the same length and return them.
Padding rows belong to HUNK-INDEX so navigation can find the block."
  (let ((budget (apply #'max (mapcar #'length panes))))
    (mapcar (lambda (rows)
              (append rows (claude-code-ide-review--padding-rows (- budget (length rows)) hunk-index)))
            panes)))

(defun claude-code-ide-review--span-length (hunk old-pos)
  "Unchanged lines between OLD-POS and HUNK in the baseline file.
For a pure insertion git reports the line the text was inserted after,
so that line is part of the span."
  (let ((start (claude-code-ide-review-hunk-old-start hunk)))
    (if (= (claude-code-ide-review-hunk-old-count hunk) 0)
        (1+ (- start old-pos))
      (- start old-pos))))

(defun claude-code-ide-review--build-rows (project-dir file)
  "Return a vector of four equal-length row lists for FILE, one per pane.
Pane 0 shows the baseline text, pane 1 the working text, pane 2 Claude's
justifications and pane 3 the user's comments.  Hunk N occupies the same
line range in all four lists."
  (let* ((old-lines (claude-code-ide-review--text-lines
                     (claude-code-ide-review-baseline-content project-dir file)))
         (hunks (claude-code-ide-review-hunks project-dir file))
         (panes (list '() '() '() '()))
         (old-pos 1)
         (new-pos 1)
         (append-segment
          (lambda (segment)
            (setq panes (cl-mapcar #'append panes segment)))))
    (cl-loop
     for hunk in hunks
     for index from 0
     do (let* ((span (claude-code-ide-review--span-length hunk old-pos))
               (lines (seq-subseq old-lines (1- old-pos) (+ (1- old-pos) span)))
               (claude-status (claude-code-ide-review-hunk-status project-dir hunk 'claude hunks))
               (user-status (claude-code-ide-review-hunk-status project-dir hunk 'user hunks)))
          ;; Unchanged span before the hunk
          (funcall append-segment
                   (claude-code-ide-review--pad-segment
                    (list (claude-code-ide-review--context-rows lines old-pos (> index 0) t)
                          (claude-code-ide-review--context-rows lines new-pos (> index 0) t)
                          '() '())
                    nil))
          ;; The hunk
          (funcall append-segment
                   (claude-code-ide-review--pad-segment
                    (list (claude-code-ide-review--diff-rows
                           (claude-code-ide-review-hunk-removed hunk) 'removed
                           (claude-code-ide-review-hunk-old-start hunk) index)
                          (claude-code-ide-review--diff-rows
                           (claude-code-ide-review-hunk-added hunk) 'added
                           (claude-code-ide-review-hunk-new-start hunk) index)
                          (claude-code-ide-review--block-rows
                           index hunk (car claude-status) (cdr claude-status) 'claude)
                          (claude-code-ide-review--block-rows
                           index hunk (car user-status) (cdr user-status) 'user))
                    index))
          (setq old-pos (+ old-pos span (claude-code-ide-review-hunk-old-count hunk))
                new-pos (+ new-pos span (claude-code-ide-review-hunk-new-count hunk)))))
    ;; Unchanged span after the last hunk
    (let ((lines (seq-subseq old-lines (min (1- old-pos) (length old-lines)))))
      (funcall append-segment
               (claude-code-ide-review--pad-segment
                (list (claude-code-ide-review--context-rows lines old-pos (consp hunks) nil)
                      (claude-code-ide-review--context-rows lines new-pos (consp hunks) nil)
                      '() '())
                nil)))
    (vconcat panes)))

(defun claude-code-ide-review--hunk-line-range (rows hunk-index)
  "Return (FIRST . LAST), the 1-based line range of HUNK-INDEX in ROWS, or nil."
  (let ((first nil)
        (last nil))
    (cl-loop for row in rows
             for line from 1
             when (eql (claude-code-ide-review-row-hunk row) hunk-index)
             do (setq first (or first line)
                      last line))
    (and first (cons first last))))

;;; Rendering rows into buffers

(defconst claude-code-ide-review--pane-names '("old" "new" "claude" "user")
  "Buffer name component of panes 0 to 3.")

(defvar-local claude-code-ide-review--rows nil
  "Row list this review buffer was rendered from.")

(defvar-local claude-code-ide-review--file nil
  "File, relative to the repository toplevel, shown in this review buffer.")

(defvar-local claude-code-ide-review--project-dir nil
  "Project directory this review buffer belongs to.")

(defun claude-code-ide-review--pane-buffer (pane file)
  "Return the buffer of PANE (0 to 3) for FILE, creating it if needed."
  (get-buffer-create (format "*claude-review: %s %s*"
                             (nth pane claude-code-ide-review--pane-names) file)))

(defun claude-code-ide-review--row-face (row)
  "Return the face for ROW, or nil for plain text."
  (pcase (claude-code-ide-review-row-kind row)
    ('removed 'claude-code-ide-review-removed)
    ('added 'claude-code-ide-review-added)
    ('padding 'claude-code-ide-review-padding)
    ('fold 'claude-code-ide-review-fold)
    ('header 'claude-code-ide-review-header)
    ('placeholder 'claude-code-ide-review-placeholder)
    (_ nil)))

(defun claude-code-ide-review--insert-row (row)
  "Insert ROW as one line at point with its text properties.
Every line carries `claude-review-hunk' (the row's hunk index or nil)
and `claude-review-kind'; padding rows also carry
`claude-review-padding' t.  Diff rows show their original line number
through `line-prefix'."
  (let ((start (point))
        (face (claude-code-ide-review--row-face row))
        (line (claude-code-ide-review-row-line row)))
    (insert (claude-code-ide-review-row-text row) "\n")
    (add-text-properties
     start (point)
     (append (list 'claude-review-hunk (claude-code-ide-review-row-hunk row)
                   'claude-review-kind (claude-code-ide-review-row-kind row))
             (when (eq (claude-code-ide-review-row-kind row) 'padding)
               (list 'claude-review-padding t))
             (when face (list 'face face))
             (when line
               (list 'line-prefix
                     (propertize (format "%4d " line)
                                 'face 'claude-code-ide-review-line-number)))))))

(defun claude-code-ide-review--render-rows (buffer rows)
  "Replace BUFFER's text with ROWS, one per line; see `--insert-row'.
The buffer is left read-only with `truncate-lines' on and line numbers
off, so buffer line equals screen row and the panes can be aligned by
line number.  Modification hooks are suppressed: the comment pane's
save-on-change hook must not see the rendering itself."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (erase-buffer)
      (dolist (row rows)
        (claude-code-ide-review--insert-row row))
      (setq claude-code-ide-review--rows rows)
      (setq truncate-lines t)
      (when (bound-and-true-p display-line-numbers-mode)
        (display-line-numbers-mode -1))
      (setq buffer-read-only t)
      (goto-char (point-min)))
    buffer))

(defun claude-code-ide-review-render-file (project-dir file)
  "Build and render the four pane buffers for FILE in PROJECT-DIR.
Returns the list of buffers, panes 0 to 3."
  (let ((rows (claude-code-ide-review--build-rows project-dir file)))
    (cl-loop for pane from 0 to 3
             collect (let ((buffer (claude-code-ide-review--pane-buffer pane file)))
                       (claude-code-ide-review--render-rows buffer (aref rows pane))
                       (with-current-buffer buffer
                         (setq claude-code-ide-review--file file
                               claude-code-ide-review--project-dir project-dir))
                       buffer))))

;;; View: windows, navigation, file switching

(defface claude-code-ide-review-current
  '((t :inherit highlight))
  "Face of the current hunk's block in every pane."
  :group 'claude-code-ide-review)

(cl-defstruct claude-code-ide-review-view
  "The one open review view."
  project-dir ; project whose baseline is reviewed
  file        ; file shown, relative to the repository toplevel
  hunks       ; the file's hunks as rendered, so keystrokes need no git call
  buffers     ; the four pane buffers, panes 0 to 3
  windows     ; the four windows showing them, same order
  hunk        ; index of the current hunk, nil when the file has none
  overlays    ; one highlight overlay per pane, same order as BUFFERS
  body-start  ; marker before the editable comment body in pane 3
  body-end    ; marker on the read-only newline that closes that body
  watch       ; file-notify descriptor on the shown file's directory, or nil
  watch-dir   ; the directory WATCH observes
  timer       ; pending rebuild timer, or nil
  restore)    ; (tab . NAME) or (winconf . CONFIGURATION), undone by quit

(defvar claude-code-ide-review--view nil
  "The open review view, or nil.  One view per Emacs session.")

(defvar claude-code-ide-review--syncing nil
  "Non-nil while the panes are being scrolled together, to stop re-entry.")

(defvar claude-code-ide-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "n" #'claude-code-ide-review-next-hunk)
    (define-key map "p" #'claude-code-ide-review-previous-hunk)
    (define-key map "g" #'claude-code-ide-review-refresh)
    (define-key map "o" #'claude-code-ide-review-select-file)
    (define-key map "e" #'claude-code-ide-review-explain-hunk)
    (define-key map "f" #'claude-code-ide-review-finish)
    (define-key map "q" #'claude-code-ide-review-quit)
    map)
  "Keys of panes 0 to 2.")

(define-derived-mode claude-code-ide-review-mode special-mode "Review"
  "Major mode of the diff panes and the justification pane.
\\{claude-code-ide-review-mode-map}"
  (setq truncate-lines t))

(defvar claude-code-ide-review-comment-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-n") #'claude-code-ide-review-next-hunk)
    (define-key map (kbd "C-c C-p") #'claude-code-ide-review-previous-hunk)
    (define-key map (kbd "C-c C-g") #'claude-code-ide-review-refresh)
    (define-key map (kbd "C-c C-o") #'claude-code-ide-review-select-file)
    (define-key map (kbd "C-c C-e") #'claude-code-ide-review-explain-hunk)
    (define-key map (kbd "C-c C-f") #'claude-code-ide-review-finish)
    (define-key map (kbd "C-c C-q") #'claude-code-ide-review-quit)
    map)
  "Keys of the user comment pane.  Plain letters are left free for typing.")

(define-derived-mode claude-code-ide-review-comment-mode text-mode "Review-Comment"
  "Major mode of the user comment pane.
\\{claude-code-ide-review-comment-mode-map}"
  (setq truncate-lines t))

(defun claude-code-ide-review--view-check ()
  "Return the open view or signal a `user-error'."
  (or claude-code-ide-review--view
      (user-error "No review view is open; use claude-code-ide-review-open")))

(defun claude-code-ide-review--line-position (line)
  "Return the position of the start of LINE (1-based) in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (point)))

(defun claude-code-ide-review--prepare-buffer (buffer pane project-dir)
  "Give BUFFER of PANE its major mode and PROJECT-DIR as default directory.
The mode is set before rendering, because changing a major mode kills
the buffer-local variables rendering stores."
  (with-current-buffer buffer
    (let ((mode (if (= pane 3)
                    'claude-code-ide-review-comment-mode
                  'claude-code-ide-review-mode)))
      (unless (derived-mode-p mode)
        (funcall mode)))
    (setq default-directory project-dir)))

(defun claude-code-ide-review--update-mode-line (view)
  "Show file, hunk position and HEAD state in pane 0's mode line for VIEW."
  (with-current-buffer (car (claude-code-ide-review-view-buffers view))
    (let ((count (length (claude-code-ide-review-view-hunks view))))
      (setq mode-line-format
            (list " " (claude-code-ide-review-view-file view)
                  (if (claude-code-ide-review-view-hunk view)
                      (format "  hunk %d/%d" (1+ (claude-code-ide-review-view-hunk view)) count)
                    "  no hunks")
                  (if (claude-code-ide-review-head-moved-p
                       (claude-code-ide-review-view-project-dir view))
                      "  HEAD moved"
                    "")))
      (force-mode-line-update))))

(defun claude-code-ide-review--sync-windows (source)
  "Make every other pane window start at the same line as SOURCE.
All four buffers have the same number of lines, so equal first lines
mean aligned panes."
  (when-let* ((view claude-code-ide-review--view)
              ((window-live-p source)))
    (let ((line (with-current-buffer (window-buffer source)
                  (line-number-at-pos (window-start source)))))
      (dolist (window (claude-code-ide-review-view-windows view))
        (when (and (window-live-p window) (not (eq window source)))
          (with-current-buffer (window-buffer window)
            (set-window-start window (claude-code-ide-review--line-position line) t)))))))

(defun claude-code-ide-review--on-scroll (window _start)
  "`window-scroll-functions' member: follow WINDOW when it is a pane."
  (when (and claude-code-ide-review--view
             (not claude-code-ide-review--syncing)
             (memq window (claude-code-ide-review-view-windows claude-code-ide-review--view)))
    (let ((claude-code-ide-review--syncing t))
      (claude-code-ide-review--sync-windows window))))

(defun claude-code-ide-review--scroll-to-line (view line)
  "Start every window of VIEW at LINE."
  (let ((claude-code-ide-review--syncing t))
    (dolist (window (claude-code-ide-review-view-windows view))
      (when (window-live-p window)
        (with-current-buffer (window-buffer window)
          (set-window-start window (claude-code-ide-review--line-position (max 1 line)) t))))))

;;; Editable comment body in pane 3

(defun claude-code-ide-review--comment-buffer (view)
  "Return VIEW's pane 3 buffer."
  (nth 3 (claude-code-ide-review-view-buffers view)))

(defun claude-code-ide-review--init-comment-pane (view)
  "Make VIEW's pane 3 a writable buffer whose text is all read-only.
The current hunk's body is opened by `--set-editable-block'.  The
save-on-change hook is installed buffer-locally."
  (with-current-buffer (claude-code-ide-review--comment-buffer view)
    (setq buffer-read-only nil)
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (put-text-property (point-min) (point-max) 'read-only t))
    (unless (markerp (claude-code-ide-review-view-body-start view))
      (setf (claude-code-ide-review-view-body-start view) (make-marker)
            (claude-code-ide-review-view-body-end view) (make-marker))
      (set-marker-insertion-type (claude-code-ide-review-view-body-end view) t))
    (add-hook 'after-change-functions #'claude-code-ide-review--comment-changed nil t)))

(defun claude-code-ide-review--body-bounds (rows index)
  "Return (FIRST . LAST) line numbers of hunk INDEX's note rows in ROWS, or nil."
  (let ((first nil)
        (last nil))
    (cl-loop for row in rows
             for line from 1
             when (and (eql (claude-code-ide-review-row-hunk row) index)
                       (eq (claude-code-ide-review-row-kind row) 'note))
             do (setq first (or first line)
                      last line))
    (and first (cons first last))))

(defun claude-code-ide-review--set-editable-block (view index)
  "Make hunk INDEX's comment body the only writable text of VIEW's pane 3.
The body is the text of the hunk's note rows up to, not including, its
closing newline, which stays read-only so the body cannot be joined
with the row below.  The header line's newline becomes rear-nonsticky
so typing into an empty body is allowed and inherits none of the
header's properties."
  (with-current-buffer (claude-code-ide-review--comment-buffer view)
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t)
          (body-start (claude-code-ide-review-view-body-start view))
          (body-end (claude-code-ide-review-view-body-end view)))
      (put-text-property (point-min) (point-max) 'read-only t)
      (remove-list-of-text-properties (point-min) (point-max) '(rear-nonsticky))
      (if-let* ((bounds (and index
                             (claude-code-ide-review--body-bounds
                              claude-code-ide-review--rows index))))
          (let ((start (claude-code-ide-review--line-position (car bounds)))
                (end (1- (claude-code-ide-review--line-position (1+ (cdr bounds))))))
            (remove-list-of-text-properties start end '(read-only))
            (put-text-property (1- start) start 'rear-nonsticky t)
            (set-marker body-start start)
            (set-marker body-end end))
        (set-marker body-start nil)
        (set-marker body-end nil)))))

(defun claude-code-ide-review--body-text (view)
  "Return the current comment body of VIEW's pane 3 as a string."
  (with-current-buffer (claude-code-ide-review--comment-buffer view)
    (buffer-substring-no-properties (claude-code-ide-review-view-body-start view)
                                    (claude-code-ide-review-view-body-end view))))

(defun claude-code-ide-review--insert-lines (buffer line rows)
  "Insert ROWS as lines before LINE in BUFFER and splice them into its row list.
In pane 3 the new text is read-only like the rest of the frame."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (save-excursion
        (goto-char (claude-code-ide-review--line-position line))
        (let ((start (point)))
          (dolist (row rows)
            (claude-code-ide-review--insert-row row))
          (when (derived-mode-p 'claude-code-ide-review-comment-mode)
            (put-text-property start (point) 'read-only t))))
      (setq claude-code-ide-review--rows
            (append (seq-take claude-code-ide-review--rows (1- line))
                    rows
                    (seq-drop claude-code-ide-review--rows (1- line)))))))

(defun claude-code-ide-review--delete-lines (buffer line count)
  "Delete COUNT lines starting at LINE in BUFFER and from its row list."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (delete-region (claude-code-ide-review--line-position line)
                     (claude-code-ide-review--line-position (+ line count)))
      (setq claude-code-ide-review--rows
            (append (seq-take claude-code-ide-review--rows (1- line))
                    (seq-drop claude-code-ide-review--rows (+ line count -1)))))))

(defun claude-code-ide-review--restretch-overlays (view index)
  "Cover hunk INDEX's block with VIEW's highlight overlay in every pane."
  (cl-loop for buffer in (claude-code-ide-review-view-buffers view)
           for overlay in (claude-code-ide-review-view-overlays view)
           do (with-current-buffer buffer
                (when-let* ((range (claude-code-ide-review--hunk-line-range
                                    claude-code-ide-review--rows index)))
                  (move-overlay overlay
                                (claude-code-ide-review--line-position (car range))
                                (claude-code-ide-review--line-position (1+ (cdr range)))
                                buffer)))))

(defun claude-code-ide-review--fit-block (view)
  "Re-align the panes after the comment body of VIEW's current hunk changed.
Growth first consumes pane 3's own padding rows for the hunk; beyond
that, the other three panes get padding rows at the block's end so the
next hunk still starts on the same line everywhere.  Shrinking pads
pane 3 only; `claude-code-ide-review-refresh' recomputes a tight layout."
  (let* ((index (claude-code-ide-review-view-hunk view))
         (pane3 (claude-code-ide-review--comment-buffer view))
         (rows3 (buffer-local-value 'claude-code-ide-review--rows pane3))
         (body-lines (1+ (cl-count ?\n (claude-code-ide-review--body-text view))))
         (note-rows (cl-count-if (lambda (row)
                                   (and (eql (claude-code-ide-review-row-hunk row) index)
                                        (eq (claude-code-ide-review-row-kind row) 'note)))
                                 rows3))
         (padding-rows (cl-count-if (lambda (row)
                                      (and (eql (claude-code-ide-review-row-hunk row) index)
                                           (eq (claude-code-ide-review-row-kind row) 'padding)))
                                    rows3))
         (delta (- body-lines note-rows))
         (body (claude-code-ide-review--body-bounds rows3 index)))
    (unless (zerop delta)
      ;; Bring pane 3's row list in step with the text the user typed
      (with-current-buffer pane3
        (setq claude-code-ide-review--rows
              (if (> delta 0)
                  (append (seq-take rows3 (cdr body))
                          (cl-loop repeat delta
                                   collect (make-claude-code-ide-review-row
                                            :text "" :kind 'note :hunk index))
                          (seq-drop rows3 (cdr body)))
                (append (seq-take rows3 (+ (cdr body) delta))
                        (seq-drop rows3 (cdr body))))))
      (let ((block-end (cdr (claude-code-ide-review--hunk-line-range
                             (buffer-local-value 'claude-code-ide-review--rows pane3)
                             index))))
        (cond
         ((> delta 0)
          (let* ((consume (min delta padding-rows))
                 (extra (- delta consume)))
            (when (> consume 0)
              (claude-code-ide-review--delete-lines pane3 (1+ (- block-end consume)) consume))
            (when (> extra 0)
              (dolist (buffer (seq-take (claude-code-ide-review-view-buffers view) 3))
                (let ((end (cdr (claude-code-ide-review--hunk-line-range
                                 (buffer-local-value 'claude-code-ide-review--rows buffer)
                                 index))))
                  (claude-code-ide-review--insert-lines
                   buffer (1+ end) (claude-code-ide-review--padding-rows extra index)))))))
         (t
          (claude-code-ide-review--insert-lines
           pane3 (1+ block-end) (claude-code-ide-review--padding-rows (- delta) index)))))
      (claude-code-ide-review--restretch-overlays view index))))

(defun claude-code-ide-review--comment-changed (_beg _end _len)
  "Save the edited comment body and keep the panes aligned.
Runs from `after-change-functions' in pane 3; everything outside the
body is read-only, so any change the user makes is inside it."
  (when-let* ((view claude-code-ide-review--view)
              (index (claude-code-ide-review-view-hunk view))
              (hunk (nth index (claude-code-ide-review-view-hunks view)))
              ((marker-position (claude-code-ide-review-view-body-start view))))
    (let ((dir (claude-code-ide-review-view-project-dir view))
          (text (claude-code-ide-review--body-text view)))
      ;; Typed text inherits nothing from the non-sticky header newline, so
      ;; stamp the body with the properties every other row carries
      (with-current-buffer (claude-code-ide-review--comment-buffer view)
        (let ((inhibit-modification-hooks t))
          (add-text-properties (claude-code-ide-review-view-body-start view)
                               (claude-code-ide-review-view-body-end view)
                               (list 'claude-review-hunk index
                                     'claude-review-kind 'note))))
      (if (string-blank-p text)
          (claude-code-ide-review-remove-note dir (claude-code-ide-review-hunk-id hunk) 'user)
        (claude-code-ide-review-put-note dir hunk 'user text))
      (claude-code-ide-review--fit-block view))))

(defun claude-code-ide-review-select-hunk (index)
  "Make hunk INDEX current in the open view.
Moves the highlight overlays, puts point on the hunk's first line in
every pane (on the comment body in pane 3), opens that body for
editing and scrolls the panes so the hunk sits near the top."
  (let* ((view (claude-code-ide-review--view-check))
         (first nil))
    (setf (claude-code-ide-review-view-hunk view) index)
    (cl-loop for buffer in (claude-code-ide-review-view-buffers view)
             for window in (claude-code-ide-review-view-windows view)
             for overlay in (claude-code-ide-review-view-overlays view)
             do (with-current-buffer buffer
                  (if-let* ((range (and index
                                        (claude-code-ide-review--hunk-line-range
                                         claude-code-ide-review--rows index))))
                      (let ((start (claude-code-ide-review--line-position (car range)))
                            (end (claude-code-ide-review--line-position (1+ (cdr range)))))
                        (setq first (car range))
                        (move-overlay overlay start end buffer)
                        (goto-char start)
                        (when (window-live-p window)
                          (set-window-point window start)))
                    (move-overlay overlay (point-min) (point-min) buffer))))
    (claude-code-ide-review--set-editable-block view index)
    (when-let* ((body-start (claude-code-ide-review-view-body-start view))
                ((marker-position body-start)))
      (with-current-buffer (claude-code-ide-review--comment-buffer view)
        (goto-char body-start)
        (let ((window (nth 3 (claude-code-ide-review-view-windows view))))
          (when (window-live-p window)
            (set-window-point window body-start)))))
    (when first
      (claude-code-ide-review--scroll-to-line view (- first 2)))
    (claude-code-ide-review--update-mode-line view)
    index))

(defun claude-code-ide-review-next-hunk ()
  "Make the next hunk current."
  (interactive)
  (let* ((view (claude-code-ide-review--view-check))
         (hunk (claude-code-ide-review-view-hunk view))
         (count (length (claude-code-ide-review-view-hunks view))))
    (cond
     ((null hunk) (message "This file has no hunks"))
     ((>= (1+ hunk) count) (message "Last hunk"))
     (t (claude-code-ide-review-select-hunk (1+ hunk))))))

(defun claude-code-ide-review-previous-hunk ()
  "Make the previous hunk current."
  (interactive)
  (let* ((view (claude-code-ide-review--view-check))
         (hunk (claude-code-ide-review-view-hunk view)))
    (cond
     ((null hunk) (message "This file has no hunks"))
     ((= hunk 0) (message "First hunk"))
     (t (claude-code-ide-review-select-hunk (1- hunk))))))

(defun claude-code-ide-review--kill-pane-buffers (view)
  "Kill VIEW's pane buffers and delete its overlays."
  (dolist (overlay (claude-code-ide-review-view-overlays view))
    (delete-overlay overlay))
  (dolist (buffer (claude-code-ide-review-view-buffers view))
    (when (buffer-live-p buffer)
      (kill-buffer buffer)))
  (setf (claude-code-ide-review-view-overlays view) nil
        (claude-code-ide-review-view-buffers view) nil))

(defun claude-code-ide-review--file-path (project-dir file)
  "Return the absolute path of FILE, relative to PROJECT-DIR's repository toplevel."
  (expand-file-name file
                    (claude-code-ide-review-baseline-toplevel
                     (claude-code-ide-review-baseline project-dir))))

;;; Live sync

(defun claude-code-ide-review--unwatch (view)
  "Drop VIEW's directory watch and any rebuild it had scheduled."
  (when (timerp (claude-code-ide-review-view-timer view))
    (cancel-timer (claude-code-ide-review-view-timer view)))
  (setf (claude-code-ide-review-view-timer view) nil)
  (when-let* ((watch (claude-code-ide-review-view-watch view)))
    ;; The directory may be gone already; a stale descriptor is no error
    (ignore-errors (file-notify-rm-watch watch)))
  (setf (claude-code-ide-review-view-watch view) nil
        (claude-code-ide-review-view-watch-dir view) nil))

(defun claude-code-ide-review--watch-file (view)
  "Watch the directory of the file VIEW shows, replacing a watch elsewhere.
The directory rather than the file is watched because a save that
renames the old file away (Emacs backups, write-through-temporary
tools) would leave a watch on the file following the old inode."
  (let ((dir (file-name-directory
              (claude-code-ide-review--file-path (claude-code-ide-review-view-project-dir view)
                                                 (claude-code-ide-review-view-file view)))))
    (unless (equal dir (claude-code-ide-review-view-watch-dir view))
      (claude-code-ide-review--unwatch view)
      (when (and claude-code-ide-review-sync-delay (file-directory-p dir))
        (setf (claude-code-ide-review-view-watch view)
              (ignore-errors
                (file-notify-add-watch dir '(change) #'claude-code-ide-review--on-file-event))
              (claude-code-ide-review-view-watch-dir view) dir)))))

(defun claude-code-ide-review--event-names-shown-file-p (view event)
  "Return non-nil when file-notify EVENT concerns the file VIEW shows.
EVENT is (DESCRIPTOR ACTION FILE [FILE1]); a rename carries both the
old and the new name, and either one counts."
  (let ((shown (file-truename
                (claude-code-ide-review--file-path (claude-code-ide-review-view-project-dir view)
                                                   (claude-code-ide-review-view-file view)))))
    (seq-some (lambda (name)
                (and (stringp name)
                     (equal (file-truename name) shown)))
              (list (nth 2 event) (nth 3 event)))))

(defun claude-code-ide-review--on-file-event (event)
  "Schedule a rebuild of the open view when EVENT touches the file it shows.
Repeated events within `claude-code-ide-review-sync-delay' collapse
into one rebuild."
  (when-let* ((view claude-code-ide-review--view)
              ((memq (nth 1 event) '(created changed deleted renamed attribute-changed)))
              ((claude-code-ide-review--event-names-shown-file-p view event)))
    (when (timerp (claude-code-ide-review-view-timer view))
      (cancel-timer (claude-code-ide-review-view-timer view)))
    (setf (claude-code-ide-review-view-timer view)
          (run-with-idle-timer claude-code-ide-review-sync-delay nil
                               #'claude-code-ide-review--sync-rebuild))))

(defun claude-code-ide-review--sync-rebuild ()
  "Rebuild the open view after a file change; the timer's function."
  (when-let* ((view claude-code-ide-review--view))
    (setf (claude-code-ide-review-view-timer view) nil)
    (claude-code-ide-review-refresh)))

(defun claude-code-ide-review--body-offset (view)
  "Return point's offset into the comment body of VIEW's pane 3, or nil.
Nil when point is outside the body, so a rebuild leaves it to
`claude-code-ide-review-select-hunk'."
  (when-let* ((start (claude-code-ide-review-view-body-start view))
              (end (claude-code-ide-review-view-body-end view))
              ((marker-position start)))
    (with-current-buffer (claude-code-ide-review--comment-buffer view)
      (when (<= start (point) end)
        (- (point) start)))))

(defun claude-code-ide-review--goto-body-offset (view offset)
  "Put point OFFSET characters into the comment body of VIEW's pane 3.
Clamped to the body, which may have become shorter."
  (when-let* ((start (claude-code-ide-review-view-body-start view))
              (end (claude-code-ide-review-view-body-end view))
              ((marker-position start)))
    (with-current-buffer (claude-code-ide-review--comment-buffer view)
      (let ((position (min (+ start offset) (marker-position end)))
            (window (nth 3 (claude-code-ide-review-view-windows view))))
        (goto-char position)
        (when (window-live-p window)
          (set-window-point window position))))))

(defun claude-code-ide-review--show-file (view file &optional hunk)
  "Render FILE into VIEW's windows and select HUNK (default 0).
Starts watching FILE's directory so later changes rebuild the panes."
  (let ((project-dir (claude-code-ide-review-view-project-dir view))
        (old-buffers (claude-code-ide-review-view-buffers view)))
    (setf (claude-code-ide-review-view-file view) file)
    (dotimes (pane 4)
      (claude-code-ide-review--prepare-buffer
       (claude-code-ide-review--pane-buffer pane file) pane project-dir))
    (let ((buffers (claude-code-ide-review-render-file project-dir file)))
      (setf (claude-code-ide-review-view-buffers view) buffers)
      (dolist (overlay (claude-code-ide-review-view-overlays view))
        (delete-overlay overlay))
      (setf (claude-code-ide-review-view-overlays view)
            (mapcar (lambda (buffer)
                      (let ((overlay (make-overlay 1 1 buffer)))
                        (overlay-put overlay 'face 'claude-code-ide-review-current)
                        overlay))
                    buffers))
      (cl-loop for buffer in buffers
               for window in (claude-code-ide-review-view-windows view)
               do (when (window-live-p window)
                    ;; `set-window-buffer' refuses a strongly dedicated window
                    (set-window-dedicated-p window nil)
                    (set-window-buffer window buffer)
                    (set-window-dedicated-p window t)))
      ;; Only now drop the previous file's buffers: killing a buffer that a
      ;; dedicated window still shows would delete that window
      (dolist (buffer old-buffers)
        (when (and (buffer-live-p buffer) (not (memq buffer buffers)))
          (kill-buffer buffer)))
      (setf (claude-code-ide-review-view-hunks view)
            (claude-code-ide-review-hunks project-dir file))
      (claude-code-ide-review--init-comment-pane view)
      (let ((count (length (claude-code-ide-review-view-hunks view))))
        (claude-code-ide-review-select-hunk
         (and (> count 0) (min (or hunk 0) (1- count)))))
      (claude-code-ide-review--watch-file view)
      (unless (claude-code-ide-review-view-hunks view)
        (if-let* ((next (car (remove file (claude-code-ide-review-changed-files project-dir)))))
            (message "%s has no changes left; %s does (o to switch)" file next)
          (message "%s has no changes left" file))))))

(defun claude-code-ide-review--create-view (project-dir)
  "Set up the 2x2 window grid for PROJECT-DIR and return the new view.
With `tab-bar-mode' on, the grid lives in a new tab named claude-review;
otherwise the current window configuration is saved for quit."
  (let ((restore (if (bound-and-true-p tab-bar-mode)
                     (progn
                       (tab-bar-new-tab)
                       (tab-bar-rename-tab "claude-review")
                       (cons 'tab "claude-review"))
                   (cons 'winconf (current-window-configuration)))))
    (delete-other-windows)
    (let* ((w0 (selected-window))
           (w2 (split-window w0 nil 'below))
           (w1 (split-window w0 nil 'right))
           (w3 (split-window w2 nil 'right)))
      (add-hook 'window-scroll-functions #'claude-code-ide-review--on-scroll)
      (setq claude-code-ide-review--view
            (make-claude-code-ide-review-view
             :project-dir (claude-code-ide-review--normalize-dir project-dir)
             :windows (list w0 w1 w2 w3)
             :restore restore)))))

(defun claude-code-ide-review--read-changed-file (project-dir)
  "Ask for one of PROJECT-DIR's changed files."
  (let ((files (claude-code-ide-review-changed-files project-dir)))
    (unless files
      (user-error "No changes since the baseline"))
    (completing-read "Review file: " files nil t)))

;;;###autoload
(defun claude-code-ide-review-open (&optional file)
  "Open the four-pane review view on FILE, or on the first changed file.
Interactively, a prefix argument asks which changed file to show.  An
open view is reused, so the command also switches files."
  (interactive
   (list (and current-prefix-arg
              (claude-code-ide-review--read-changed-file
               (if claude-code-ide-review--view
                   (claude-code-ide-review-view-project-dir claude-code-ide-review--view)
                 (claude-code-ide-review--project-dir))))))
  (let* ((project-dir (if claude-code-ide-review--view
                          (claude-code-ide-review-view-project-dir claude-code-ide-review--view)
                        (claude-code-ide-review--project-dir)))
         (files (claude-code-ide-review-changed-files project-dir))
         (file (or file (car files))))
    (unless (claude-code-ide-review-baseline project-dir)
      (user-error "No review baseline for %s" project-dir))
    (unless file
      (user-error "No changes since the baseline"))
    (let ((view (or claude-code-ide-review--view
                    (claude-code-ide-review--create-view project-dir))))
      (claude-code-ide-review--show-file view file)
      (select-window (car (claude-code-ide-review-view-windows view)))
      view)))

(defun claude-code-ide-review-select-file ()
  "Show another changed file in the open view."
  (interactive)
  (let ((view (claude-code-ide-review--view-check)))
    (claude-code-ide-review-open
     (claude-code-ide-review--read-changed-file
      (claude-code-ide-review-view-project-dir view)))))

(defun claude-code-ide-review-refresh ()
  "Re-render the file shown in the open view, keeping the current hunk.
Point in the comment body keeps its offset, so a rebuild caused by a
change to the file does not move the user's typing position."
  (interactive)
  (let* ((view (claude-code-ide-review--view-check))
         (offset (claude-code-ide-review--body-offset view)))
    (claude-code-ide-review--show-file view
                                       (claude-code-ide-review-view-file view)
                                       (claude-code-ide-review-view-hunk view))
    (when offset
      (claude-code-ide-review--goto-body-offset view offset))))

;;;###autoload
(defun claude-code-ide-review-quit ()
  "Close the review view and restore the windows or tab it replaced."
  (interactive)
  (when-let* ((view claude-code-ide-review--view))
    (remove-hook 'window-scroll-functions #'claude-code-ide-review--on-scroll)
    (claude-code-ide-review--unwatch view)
    (claude-code-ide-review--kill-pane-buffers view)
    (setq claude-code-ide-review--view nil)
    (pcase (claude-code-ide-review-view-restore view)
      (`(tab . ,name)
       (when (fboundp 'tab-bar-close-tab-by-name)
         (tab-bar-close-tab-by-name name)))
      (`(winconf . ,configuration)
       (set-window-configuration configuration)))))

;;; Formatting

(defun claude-code-ide-review--short-id (id)
  "Return the first 12 characters of hunk ID, enough to tell hunks apart."
  (substring id 0 (min 12 (length id))))

(defun claude-code-ide-review--hunk-range-string (hunk)
  "Return HUNK as FILE:START-END in working-file lines.
These are the numbers `review_annotate' accepts, so Claude can copy
them back from `review_list_hunks' output."
  (let ((start (claude-code-ide-review-hunk-new-start hunk)))
    (format "%s:%d-%d"
            (claude-code-ide-review-hunk-file hunk)
            start
            (claude-code-ide-review--range-end start (claude-code-ide-review-hunk-new-count hunk)))))

(defun claude-code-ide-review--diff-block (hunk)
  "Return HUNK's removed and added text as a fenced diff block.
Built from the hunk's own text rather than from git, so the output is
the same wherever it is rendered."
  (cl-flet ((lines (text prefix)
              (if (string-empty-p text)
                  ""
                (mapconcat (lambda (line) (concat prefix line "\n"))
                           (split-string text "\n")
                           ""))))
    (concat "```diff\n"
            (lines (claude-code-ide-review-hunk-removed hunk) "-")
            (lines (claude-code-ide-review-hunk-added hunk) "+")
            "```")))

(defun claude-code-ide-review--format-comments (project-dir)
  "Format every user comment of PROJECT-DIR with its hunk, for the Claude prompt.
Each comment becomes a header with the hunk's file and line range, the
hunk as a diff block, and the comment text.  A comment whose hunk text
changed since it was written is marked after its header.  Comments
whose hunk disappeared are left out.  Returns nil when there is nothing
to format."
  (let ((statuses-by-file '())
        (parts '()))
    (dolist (note (claude-code-ide-review-notes project-dir 'user))
      (let* ((file (claude-code-ide-review-note-file note))
             (statuses (or (cdr (assoc file statuses-by-file))
                           (let ((computed (claude-code-ide-review-file-statuses
                                            project-dir file 'user)))
                             (push (cons file computed) statuses-by-file)
                             computed)))
             (entry (seq-find (lambda (entry) (eq (nth 2 entry) note)) statuses)))
        (when entry
          (push (format "## %s%s\n%s\nComment: %s"
                        (claude-code-ide-review--hunk-range-string (car entry))
                        (if (eq (nth 1 entry) 'stale)
                            " (hunk changed since the comment was written)"
                          "")
                        (claude-code-ide-review--diff-block (car entry))
                        (claude-code-ide-review-note-text note))
                parts))))
    (when parts
      (string-join (nreverse parts) "\n\n"))))

;;; Finish and explain

(defun claude-code-ide-review--session (project-dir)
  "Return the Claude session the review of PROJECT-DIR talks to.
Resolved like every other send command, from the project rather than
from the current buffer, because pane buffers visit no file.  Signals
a `user-error' when the project has no session."
  (let ((default-directory project-dir))
    (or (claude-code-ide--resolve-session 'auto "Send review to Claude instance: ")
        (user-error "No Claude Code session for %s" project-dir))))

(defun claude-code-ide-review--mark-comments-sent (project-dir)
  "Record that every non-blank user comment of PROJECT-DIR reached Claude.
Lifts the guard of `claude-code-ide-review-unsent-comments'.  A comment
edited afterwards is stored as a fresh note and becomes unsent again."
  (dolist (note (claude-code-ide-review-unsent-comments project-dir))
    (setf (claude-code-ide-review-note-sent note) t)))

(defun claude-code-ide-review--current-project-dir ()
  "Return the project the open view reviews, else the project of point."
  (if claude-code-ide-review--view
      (claude-code-ide-review-view-project-dir claude-code-ide-review--view)
    (claude-code-ide-review--project-dir)))

;;;###autoload
(defun claude-code-ide-review-finish ()
  "Send every user review comment, with its hunk, to the Claude prompt.
The comments are formatted by `claude-code-ide-review--format-comments'
and typed into the terminal when they fit within
`claude-code-ide-review-inline-limit'; otherwise a short prompt asks
Claude to call `review_get_comments'.  Either way the comments are
marked as sent.  Works with or without the review view open."
  (interactive)
  (let* ((dir (claude-code-ide-review--current-project-dir))
         (text (claude-code-ide-review--format-comments dir))
         (count (cl-count-if (lambda (note)
                               (not (string-blank-p (claude-code-ide-review-note-text note))))
                             (claude-code-ide-review-notes dir 'user))))
    (unless text
      (user-error "No review comments to send"))
    (claude-code-ide-send-prompt
     (if (<= (length text) claude-code-ide-review-inline-limit)
         (concat "Review comments on your changes follow. Address each one.\n\n" text)
       (format "I left %d review comment%s in Emacs. Call review_get_comments to read them, then address each one."
               count (if (= count 1) "" "s")))
     (claude-code-ide-review--session dir))
    (claude-code-ide-review--mark-comments-sent dir)
    (message "Sent %d review comment%s" count (if (= count 1) "" "s"))))

(defun claude-code-ide-review--hunk-file-path (project-dir hunk)
  "Return the absolute path of HUNK's file in PROJECT-DIR's repository."
  (claude-code-ide-review--file-path project-dir (claude-code-ide-review-hunk-file hunk)))

(defun claude-code-ide-review--send-hunk-reference (project-dir hunk session)
  "Insert HUNK's file and working-file line range into SESSION's prompt.
The range is marked as the region in a scratch buffer that visits the
real file with its on-disk content, so the prompt names that file and
the line numbers match the hunks, which also come from disk.  A buffer
the user may have open on the file is left alone, and no \"reread from
disk?\" question is asked.  A pure deletion owns no lines; the one line
git reports for it is sent, clamped to the first line when the
deletion sits at the top of the file."
  (let* ((start (max 1 (claude-code-ide-review-hunk-new-start hunk)))
         (end (claude-code-ide-review--range-end start (claude-code-ide-review-hunk-new-count hunk)))
         (path (claude-code-ide-review--hunk-file-path project-dir hunk)))
    (with-temp-buffer
      ;; VISIT sets `buffer-file-name' and leaves the buffer unmodified,
      ;; so killing it asks nothing
      (insert-file-contents path t)
      ;; `use-region-p' needs an active region, which needs
      ;; `transient-mark-mode'; bind it so the range is honoured even
      ;; where the mode is off, as in batch
      (let ((transient-mark-mode t))
        (goto-char (point-min))
        (forward-line (1- start))
        (push-mark (point) t t)
        (forward-line (- end start))
        (claude-code-ide-mcp-send-at-mentioned session))
      (setq buffer-file-name nil))))

;;;###autoload
(defun claude-code-ide-review-explain-hunk ()
  "Send the current hunk's file and line range to the Claude prompt.
The hunk then appears as a selection in the prompt, so a request such
as \"explain this part of the diff\" refers to it.  With
`claude-code-ide-review-explain-sends-prompt' non-nil the request to
justify the hunk with `review_annotate' is submitted as well."
  (interactive)
  (let* ((view (claude-code-ide-review--view-check))
         (index (or (claude-code-ide-review-view-hunk view)
                    (user-error "No hunk is selected")))
         (hunk (nth index (claude-code-ide-review-view-hunks view)))
         (dir (claude-code-ide-review-view-project-dir view))
         (session (claude-code-ide-review--session dir)))
    (claude-code-ide-review--send-hunk-reference dir hunk session)
    (when claude-code-ide-review-explain-sends-prompt
      (claude-code-ide-send-prompt
       "Explain this part of the diff and record the justification with review_annotate."
       session))
    (message "Sent %s to the Claude prompt" (claude-code-ide-review--hunk-range-string hunk))))

;;; Tools for Claude

(defun claude-code-ide-review--relative-path (baseline file-path)
  "Return FILE-PATH relative to BASELINE's repository toplevel.
An absolute path is resolved through `file-truename' first, because the
toplevel from git has symbolic links resolved.  A relative path is
returned unchanged."
  (if (file-name-absolute-p file-path)
      (file-relative-name (file-truename (expand-file-name file-path))
                          (claude-code-ide-review-baseline-toplevel baseline))
    file-path))

(defun claude-code-ide-review--no-baseline-message (project-dir)
  "Text returned by every tool when PROJECT-DIR has no review baseline."
  (format "No review baseline for %s; call review_mark_baseline first" project-dir))

(defun claude-code-ide-review--status-line (hunk status note)
  "One `review_list_hunks' line for HUNK with STATUS and NOTE."
  (format "%s  id=%s  status=%s%s"
          (claude-code-ide-review--hunk-range-string hunk)
          (claude-code-ide-review--short-id (claude-code-ide-review-hunk-id hunk))
          status
          (if note
              (format "  %S" (claude-code-ide-review-note-text note))
            "")))

(defun claude-code-ide-review-tool-mark-baseline ()
  "Tool `review_mark_baseline': make the working tree the review baseline.
Refuses, changing nothing, while the user has review comments that were
never sent: the tool runs without a permission prompt, and moving the
baseline would erase them.  Only the user can reset such a review, with
the command `claude-code-ide-review-mark-baseline'."
  (let* ((dir (claude-code-ide-review--project-dir))
         (unsent (length (claude-code-ide-review-unsent-comments dir))))
    (if (> unsent 0)
        (format "Refused: %d user comment%s in the review %s not been sent yet; the baseline is unchanged. Ask the user to finish the review in Emacs, or to run M-x claude-code-ide-review-mark-baseline to discard the comments."
                unsent
                (if (= unsent 1) "" "s")
                (if (= unsent 1) "has" "have"))
      (let ((baseline (claude-code-ide-review-mark-baseline dir)))
        (if baseline
            (format "Baseline set to %s"
                    (claude-code-ide-review--short-id
                     (claude-code-ide-review-baseline-commit baseline)))
          (format "No git repository at %s; no baseline recorded" dir))))))

(defun claude-code-ide-review-tool-list-hunks (&optional file-path)
  "Tool `review_list_hunks': list hunks with their justification status.
With FILE-PATH, list that file only; otherwise every changed file."
  (let* ((dir (claude-code-ide-review--project-dir))
         (baseline (claude-code-ide-review-baseline dir)))
    (if (null baseline)
        (claude-code-ide-review--no-baseline-message dir)
      (let* ((files (if file-path
                        (list (claude-code-ide-review--relative-path baseline file-path))
                      (claude-code-ide-review-changed-files dir)))
             (entries (apply #'append
                             (mapcar (lambda (file)
                                       (claude-code-ide-review-file-statuses dir file 'claude))
                                     files))))
        (if (null entries)
            "No changes since the baseline"
          (let ((statuses (mapcar #'cadr entries)))
            (concat (mapconcat (lambda (entry) (apply #'claude-code-ide-review--status-line entry))
                               entries "\n")
                    (format "\n%d hunks, %d unexplained, %d stale"
                            (length entries)
                            (cl-count 'unexplained statuses)
                            (cl-count 'stale statuses)))))))))

(defun claude-code-ide-review-tool-annotate (file-path start-line end-line justification)
  "Tool `review_annotate': store JUSTIFICATION for one hunk of FILE-PATH.
The hunk is the one overlapping lines START-LINE..END-LINE.  FILE-PATH
may be absolute or relative to the repository.  Replaces an
earlier justification for the same hunk.  When no hunk overlaps the
range, the reply lists the file's hunk ranges so the caller can
correct it."
  (let* ((dir (claude-code-ide-review--project-dir))
         (baseline (claude-code-ide-review-baseline dir)))
    (if (null baseline)
        (claude-code-ide-review--no-baseline-message dir)
      (let* ((file (claude-code-ide-review--relative-path baseline file-path))
             (hunk (claude-code-ide-review-hunk-at dir file start-line end-line)))
        (cond
         (hunk
          (claude-code-ide-review-put-note dir hunk 'claude justification)
          (format "Annotated %s (id=%s)"
                  (claude-code-ide-review--hunk-range-string hunk)
                  (claude-code-ide-review--short-id (claude-code-ide-review-hunk-id hunk))))
         (t
          (let ((hunks (claude-code-ide-review-hunks dir file)))
            (if hunks
                (format "No hunk of %s overlaps lines %d-%d. Hunks: %s"
                        file start-line end-line
                        (mapconcat #'claude-code-ide-review--hunk-range-string hunks ", "))
              (format "%s has no changes since the baseline" file)))))))))

(defun claude-code-ide-review-tool-get-comments ()
  "Tool `review_get_comments': the user's review comments with their hunks.
Reading them does not mark them sent: only the user's finish command
does, so the guard on `review_mark_baseline' holds until the user has
finished, even when Claude reads half-written comments on its own."
  (let ((dir (claude-code-ide-review--project-dir)))
    (if (null (claude-code-ide-review-baseline dir))
        (claude-code-ide-review--no-baseline-message dir)
      (or (claude-code-ide-review--format-comments dir)
          "No user comments"))))

(defun claude-code-ide-review-tool-open (&optional file-path)
  "Tool `review_open': open the four-pane review view.
Shows FILE-PATH, or the first changed file, and reports the changed
files with their hunk counts.  Without changes nothing opens."
  (let* ((dir (claude-code-ide-review--project-dir))
         (baseline (claude-code-ide-review-baseline dir)))
    (if (null baseline)
        (claude-code-ide-review--no-baseline-message dir)
      (let* ((changed (claude-code-ide-review-changed-files dir))
             (files (if file-path
                        (list (claude-code-ide-review--relative-path baseline file-path))
                      changed))
             (skipped (and (null file-path) (claude-code-ide-review-skipped-files dir)))
             (opened (when (and changed (or (null file-path) (member (car files) changed)))
                       (condition-case err
                           (progn
                             (claude-code-ide-review-open (car files))
                             (format "Opened review for %s\n" (car files)))
                         (error (format "Could not open the review view: %s\n"
                                        (error-message-string err)))))))
        (concat
         opened
         (if (null files)
             "No changes since the baseline"
           (mapconcat (lambda (file)
                        (let ((count (length (claude-code-ide-review-hunks dir file))))
                          (format "%s: %d hunk%s" file count (if (= count 1) "" "s"))))
                      files "\n"))
         (when skipped
           (format "\nSkipped %d untracked file%s over %d bytes: %s"
                   (length skipped) (if (= (length skipped) 1) "" "s")
                   claude-code-ide-review-max-file-size
                   (mapconcat #'identity skipped ", ")))
         (when (claude-code-ide-review-head-moved-p dir)
           "\nHEAD moved since the baseline and uncommitted edits remain; call review_mark_baseline to start a fresh review"))))))

;;; Prompt and system prompt

(defun claude-code-ide-review--prompt-text (rules)
  "Return the message the `/emacs-tools:review' slash command sends.
RULES is the command's optional argument; blank or nil falls back to
`claude-code-ide-review-rules'."
  (format "Review the edits made since the review baseline.
1. Call review_open to show the four-pane view.
2. Call review_list_hunks.
3. For every hunk with status unexplained or stale that you produced in this conversation, call review_annotate with a justification that follows these rules: %s
4. Leave hunks you did not make alone: the view shows a placeholder that tells the user how to send them to you.
Then report how many hunks you annotated and how many you left."
          (if (and rules (not (string-blank-p rules)))
              rules
            claude-code-ide-review-rules)))

(defun claude-code-ide-review--register-prompt ()
  "Register the `review' prompt, which Claude Code lists as a slash command."
  (claude-code-ide-make-prompt
   :name "review"
   :description "Review the edits made since the baseline in the four-pane view"
   :args '((:name "rules"
                  :description "Justification rules for this review; the claude-code-ide-review-rules option applies when omitted"
                  :optional t))
   :function #'claude-code-ide-review--prompt-text))

(defun claude-code-ide-review--system-prompt ()
  "Return the system prompt paragraph asking for annotations, or nil.
For `claude-code-ide-system-prompt-functions'; nil unless
`claude-code-ide-review-annotate-on-edit' is set."
  (when claude-code-ide-review-annotate-on-edit
    (format "After each Edit, Write, or MultiEdit call, call review_annotate for the changed line range with a one- or two-sentence justification that follows these rules: %s"
            claude-code-ide-review-rules)))

;;; PostToolUse reminder

(defun claude-code-ide-review--emacsclient-path ()
  "Return the `emacsclient' program matching the running Emacs when found."
  (let ((beside (expand-file-name "emacsclient" invocation-directory)))
    (cond
     ((file-executable-p beside) beside)
     ((executable-find "emacsclient"))
     (t "emacsclient"))))

(defun claude-code-ide-review--server-argument ()
  "Return the `emacsclient' option that selects this Emacs's server, quoted."
  (if server-use-tcp
      (concat "-f " (shell-quote-argument (expand-file-name server-name server-auth-dir)))
    (concat "-s " (shell-quote-argument server-name))))

(defun claude-code-ide-review--hook-command ()
  "Return the shell command of the PostToolUse hook.
It saves the hook input to a temporary file, has Emacs overwrite the
file with the reply through `claude-code-ide-review-hook-report', and
prints the file.  The reply travels through the file because
`emacsclient --eval' prints return values in Lisp syntax."
  (format "f=$(mktemp); cat >\"$f\"; %s %s --eval \"(claude-code-ide-review-hook-report \\\"$f\\\")\" >/dev/null 2>&1; cat \"$f\"; rm -f \"$f\""
          (shell-quote-argument (claude-code-ide-review--emacsclient-path))
          (claude-code-ide-review--server-argument)))

(defun claude-code-ide-review--settings-json ()
  "Return the JSON for `--settings' that installs the reminder hook."
  (json-encode
   `((hooks . ((PostToolUse . [((matcher . "Edit|Write|MultiEdit")
                                (hooks . [((type . "command")
                                           (command . ,(claude-code-ide-review--hook-command))
                                           (timeout . 10))]))]))))))

(defun claude-code-ide-review--command-flags ()
  "Return the `--settings' flag for the reminder hook, or nil.
For `claude-code-ide-command-flag-functions'; nil unless
`claude-code-ide-review-remind-on-edit' is set and a server runs."
  (when (and claude-code-ide-review-remind-on-edit
             (server-running-p))
    (concat "--settings " (shell-quote-argument (claude-code-ide-review--settings-json)))))

(defun claude-code-ide-review--unexplained-report (project-dir path)
  "Return a reminder about PATH's hunks without a justification, or nil.
PROJECT-DIR is the session's working directory.  Nil without a
baseline, when PATH has no hunks, or when every hunk is justified."
  (when-let* ((baseline (claude-code-ide-review-baseline project-dir))
              (file (claude-code-ide-review--relative-path baseline path))
              (pending (seq-remove (lambda (entry) (eq (nth 1 entry) 'ok))
                                   (claude-code-ide-review-file-statuses project-dir file 'claude))))
    (format "Review: %d hunk%s in %s %s no justification: %s. Call review_annotate for the ones you made."
            (length pending)
            (if (= (length pending) 1) "" "s")
            file
            (if (= (length pending) 1) "has" "have")
            (mapconcat (lambda (entry)
                         (concat (claude-code-ide-review--hunk-range-string (car entry))
                                 (if (eq (nth 1 entry) 'stale) " (stale)" "")))
                       pending ", "))))

;;;###autoload
(defun claude-code-ide-review-hook-report (file)
  "Answer the PostToolUse hook whose input JSON is in FILE.
Overwrites FILE with the hook's JSON reply, naming the edited file's
unexplained hunks, or with nothing when there is nothing to say or the
input cannot be read.  Returns nil.  Called by `emacsclient' from the
hook that `claude-code-ide-review-remind-on-edit' installs."
  (let ((reply (condition-case nil
                   (let* ((input (with-temp-buffer
                                   (insert-file-contents file)
                                   (json-parse-buffer :object-type 'alist)))
                          (cwd (alist-get 'cwd input))
                          (path (alist-get 'file_path (alist-get 'tool_input input))))
                     (and (stringp cwd) (stringp path)
                          (claude-code-ide-review--unexplained-report cwd path)))
                 (error nil))))
    (with-temp-file file
      (when reply
        (insert (json-encode `((hookSpecificOutput . ((hookEventName . "PostToolUse")
                                                      (additionalContext . ,reply))))))))
    nil))

;;; Setup

(defun claude-code-ide-review--register-tools ()
  "Register the review tools with the MCP tools server."
  (claude-code-ide-make-tool
   :function #'claude-code-ide-review-tool-mark-baseline
   :name "review_mark_baseline"
   :description "Make the current working tree the review baseline. Edits made before this call leave the review; edits made afterwards appear in it. Call it only when the user asks to start a fresh review. It refuses while the user has unsent review comments, because moving the baseline discards them."
   :args nil)
  (claude-code-ide-make-tool
   :function #'claude-code-ide-review-tool-list-hunks
   :name "review_list_hunks"
   :description "List the changed regions (hunks) since the review baseline with their justification status: ok, unexplained, or stale (the text changed after the justification was written). Each line gives file:start-end in current line numbers, which review_annotate accepts."
   :args '((:name "file_path"
                  :type string
                  :description "Limit the list to this file; omit for every changed file"
                  :optional t)))
  (claude-code-ide-make-tool
   :function #'claude-code-ide-review-tool-annotate
   :name "review_annotate"
   :description "Record a short justification for one change you made, so the user sees it beside the diff in the review view. Call it after each edit with the edited line range. Only annotate changes you made yourself; leave other hunks alone. If the reply says no hunk overlaps, use one of the ranges it lists."
   :args '((:name "file_path"
                  :type string
                  :description "Path of the edited file")
           (:name "start_line"
                  :type integer
                  :description "First edited line in the current file (1-based)")
           (:name "end_line"
                  :type integer
                  :description "Last edited line in the current file (1-based)")
           (:name "justification"
                  :type string
                  :description "One or two sentences: what changed and why")))
  (claude-code-ide-make-tool
   :function #'claude-code-ide-review-tool-open
   :name "review_open"
   :description "Open the user's review view for the edits made since the baseline."
   :args '((:name "file_path"
                  :type string
                  :description "File to show first; omit for the first changed file"
                  :optional t)))
  (claude-code-ide-make-tool
   :function #'claude-code-ide-review-tool-get-comments
   :name "review_get_comments"
   :description "Fetch the user's review comments, each with the file, line range and diff of the change it refers to. Use it when the user asks you to address their review comments."
   :args nil))

;;;###autoload
(defun claude-code-ide-review-setup ()
  "Enable the review feature for Claude Code sessions.
Attaches to the tools server session hooks so each project gets a
baseline when its first session starts, deletes the pinning refs when
Emacs exits, registers the review tools Claude can call and the
`/emacs-tools:review' slash command, and adds the annotation paragraph
to the system prompt when `claude-code-ide-review-annotate-on-edit'
is set.  Safe to call more than once."
  (interactive)
  (add-hook 'claude-code-ide-mcp-server-session-started-hook
            #'claude-code-ide-review--on-session-started)
  (add-hook 'claude-code-ide-mcp-server-session-ended-hook
            #'claude-code-ide-review--release)
  (add-hook 'kill-emacs-hook #'claude-code-ide-review--release-all)
  (add-hook 'claude-code-ide-system-prompt-functions
            #'claude-code-ide-review--system-prompt)
  (add-hook 'claude-code-ide-command-flag-functions
            #'claude-code-ide-review--command-flags)
  (when (and claude-code-ide-review-remind-on-edit
             (not (server-running-p)))
    (message "claude-code-ide-review-remind-on-edit needs a running Emacs server; run M-x server-start"))
  (claude-code-ide-review--register-tools)
  (claude-code-ide-review--register-prompt))

(provide 'claude-code-ide-review)
;;; claude-code-ide-review.el ends here
