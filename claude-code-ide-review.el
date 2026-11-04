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
(require 'ediff)
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

;;; File contents

(defcustom claude-code-ide-review-comment-lines 6
  "Height, in lines, of the justification and comment windows below the diff.
The two diff windows take the rest of the frame."
  :type 'integer
  :group 'claude-code-ide-review)

(defface claude-code-ide-review-header
  '((t :inherit bold))
  "Face for the hunk header line of the justification and comment windows."
  :group 'claude-code-ide-review)

(defface claude-code-ide-review-placeholder
  '((t :inherit font-lock-comment-face))
  "Face for the placeholder shown when Claude left no justification."
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

(defun claude-code-ide-review--placeholder-text ()
  "Return the text shown when the current hunk has no justification.
The key name follows the current binding of
`claude-code-ide-review-explain-hunk'."
  (substitute-command-keys
   "Claude did not leave a comment. This change may have been made by you. If Claude made it, press \\[claude-code-ide-review-explain-hunk] in the diff to send this hunk to the Claude prompt, then ask it to explain the change."))

;;; View: an ediff session with justification and comment windows below

(cl-defstruct claude-code-ide-review-view
  "The one open review view."
  project-dir   ; project whose baseline is reviewed
  file          ; file shown, relative to the repository toplevel
  hunks         ; the file's hunks from git, in file order
  hunk          ; index into HUNKS of the hunk under the current difference, or nil
  control       ; ediff control buffer
  old-buffer    ; read-only buffer holding the baseline text (ediff buffer A)
  file-buffer   ; buffer visiting the real file (ediff buffer B)
  claude-buffer ; window below A: the current hunk's justification
  user-buffer   ; window below B: the current hunk's comment, editable
  comment-hunk  ; the hunk USER-BUFFER currently edits, or nil
  switching     ; non-nil while ediff is restarted on another file
  watch         ; file-notify descriptor on the shown file's directory, or nil
  watch-dir     ; the directory WATCH observes
  timer         ; pending rebuild timer, or nil
  restore)      ; (tab . NAME) or (winconf . CONFIGURATION), undone by quit

(defvar claude-code-ide-review--view nil
  "The open review view, or nil.  One view per Emacs session.")

(defvar claude-code-ide-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "n" #'claude-code-ide-review-next-hunk)
    (define-key map "p" #'claude-code-ide-review-previous-hunk)
    (define-key map "g" #'claude-code-ide-review-refresh)
    (define-key map "o" #'claude-code-ide-review-select-file)
    (define-key map "e" #'claude-code-ide-review-explain-hunk)
    (define-key map "f" #'claude-code-ide-review-finish)
    (define-key map "c" #'claude-code-ide-review-comment)
    (define-key map "q" #'claude-code-ide-review-quit)
    map)
  "Keys of the justification window; also added to ediff's control window.")

(define-derived-mode claude-code-ide-review-mode special-mode "Review"
  "Major mode of the justification window.
\\{claude-code-ide-review-mode-map}"
  (setq truncate-lines nil))

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
  "Keys of the comment window.  Plain letters are left free for typing.")

(define-derived-mode claude-code-ide-review-comment-mode text-mode "Review-Comment"
  "Major mode of the comment window.
\\{claude-code-ide-review-comment-mode-map}")

(defun claude-code-ide-review--view-check ()
  "Return the open view or signal a `user-error'."
  (or claude-code-ide-review--view
      (user-error "No review view is open; use claude-code-ide-review-open")))

(defun claude-code-ide-review--file-path (project-dir file)
  "Return the absolute path of FILE, relative to PROJECT-DIR's repository toplevel."
  (expand-file-name file
                    (claude-code-ide-review-baseline-toplevel
                     (claude-code-ide-review-baseline project-dir))))

(defun claude-code-ide-review--old-buffer (project-dir file)
  "Return a fresh read-only buffer holding FILE's baseline text.
It gets the major mode the real file would, for the same highlighting."
  (let ((buffer (get-buffer-create (format "*claude-review: baseline %s*" file)))
        (path (claude-code-ide-review--file-path project-dir file)))
    (with-current-buffer buffer
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert (claude-code-ide-review-baseline-content project-dir file))
      (goto-char (point-min))
      (let ((buffer-file-name path))
        (ignore-errors (set-auto-mode)))
      (setq default-directory (file-name-directory path))
      (set-buffer-modified-p nil)
      (setq buffer-read-only t))
    buffer))

(defun claude-code-ide-review--side-buffer (view name mode)
  "Return VIEW's bottom buffer called NAME in major MODE, creating it."
  (let ((buffer (get-buffer-create (format "*claude-review: %s*" name))))
    (with-current-buffer buffer
      (unless (derived-mode-p mode)
        (funcall mode))
      (setq default-directory (claude-code-ide-review-view-project-dir view)))
    buffer))

;;; View: window layout

(defvar ediff-window-A)
(defvar ediff-window-B)
(defvar ediff-control-window)
(defvar ediff-current-difference)
(defvar ediff-number-of-differences)
(defvar ediff-buffer-A)
(defvar ediff-buffer-B)
(defvar ediff-control-buffer)
(defvar ediff-mode-map)
(defvar ediff-after-quit-hook-internal)
(defvar ediff-window-setup-function)
(defvar ediff-split-window-function)
(declare-function ediff-buffers "ediff" (buffer-a buffer-b &optional startup-hooks job-name))
(declare-function ediff-setup-control-buffer "ediff-wind" (ctl-buf))
(declare-function ediff-destroy-control-frame "ediff-wind" (ctl-buf))
(declare-function ediff-get-diff-posn "ediff-util" (buf-type pos &optional n control-buf))
(declare-function ediff-jump-to-difference "ediff-util" (difference-number))
(declare-function ediff-next-difference "ediff-util" (&optional arg))
(declare-function ediff-previous-difference "ediff-util" (&optional arg))
(declare-function ediff-really-quit "ediff-util" (reverse-default-keep-variants))
(declare-function ediff-update-diffs "ediff-util" ())

(defun claude-code-ide-review--setup-windows (buffer-a buffer-b _buffer-c control-buffer)
  "Arrange the review windows; the view's `ediff-window-setup-function'.
BUFFER-A and BUFFER-B fill the top row.  Below them the justification
and comment windows take `claude-code-ide-review-comment-lines' lines,
and CONTROL-BUFFER sits at the bottom.  Called by ediff at setup and
whenever it decides the windows need rebuilding."
  (ediff-destroy-control-frame control-buffer)
  (let ((view claude-code-ide-review--view)
        (window-min-height 1))
    (when (or (window-minibuffer-p) (window-parameter nil 'window-side))
      (select-window (window-main-window)))
    (delete-other-windows)
    (set-window-dedicated-p (selected-window) nil)
    (let* ((window-a (selected-window))
           ;; Sizes count the mode line, and the comment windows carry a
           ;; header line too; the control window gets 3 and shrinks
           (window-claude (split-window window-a
                                        (- (+ claude-code-ide-review-comment-lines 5))
                                        'below))
           (window-control (split-window window-claude -3 'below))
           (window-b (split-window window-a nil 'right))
           (window-user (split-window window-claude nil 'right)))
      (set-window-buffer window-a buffer-a)
      (set-window-buffer window-b buffer-b)
      (when view
        (set-window-buffer window-claude (claude-code-ide-review-view-claude-buffer view))
        (set-window-buffer window-user (claude-code-ide-review-view-user-buffer view)))
      (set-window-buffer window-control control-buffer)
      (with-current-buffer control-buffer
        (setq ediff-window-A window-a
              ediff-window-B window-b
              ediff-control-window window-control))
      (select-window window-control)
      (ediff-setup-control-buffer control-buffer))))

(defun claude-code-ide-review--after-setup-windows ()
  "`ediff-after-setup-windows-hook' member: restore our layout when lost.
On a text terminal ediff forces its plain layout on every window
rebuild, which drops the bottom windows; put them back for our session."
  (when-let* ((view claude-code-ide-review--view)
              ((eq (current-buffer) (claude-code-ide-review-view-control view)))
              ((not (get-buffer-window (claude-code-ide-review-view-user-buffer view)))))
    (claude-code-ide-review--setup-windows ediff-buffer-A ediff-buffer-B nil (current-buffer))))

;;; View: the current difference and the bottom windows

(defun claude-code-ide-review--difference-lines (view n)
  "Return (START . END) working-file lines of ediff difference N in VIEW.
A difference that adds nothing in the working file, a pure deletion,
reports the one line git would, so the hunk lookup still matches."
  (with-current-buffer (claude-code-ide-review-view-control view)
    (let ((beg (ediff-get-diff-posn 'B 'beg n))
          (end (ediff-get-diff-posn 'B 'end n)))
      (with-current-buffer ediff-buffer-B
        (let ((start (line-number-at-pos beg)))
          (if (= beg end)
              ;; An empty region sits where the deleted lines were; git
              ;; reports the line before it, so cover both
              (cons (max 0 (1- start)) start)
            ;; END is the start of the line after the region, so the
            ;; character before it ends the last changed line
            (cons start (line-number-at-pos (1- end)))))))))

(defun claude-code-ide-review--difference-count (view)
  "Return the number of ediff differences in VIEW."
  (with-current-buffer (claude-code-ide-review-view-control view)
    ediff-number-of-differences))

(defun claude-code-ide-review--current-difference (view)
  "Return the index of VIEW's selected ediff difference, or nil."
  (with-current-buffer (claude-code-ide-review-view-control view)
    (and (>= ediff-current-difference 0)
         (< ediff-current-difference ediff-number-of-differences)
         ediff-current-difference)))

(defun claude-code-ide-review--hunk-for-difference (view n)
  "Return the index in VIEW's hunks of the hunk under ediff difference N, or nil."
  (let* ((range (claude-code-ide-review--difference-lines view n))
         (hunk (claude-code-ide-review-hunk-at (claude-code-ide-review-view-project-dir view)
                                               (claude-code-ide-review-view-file view)
                                               (car range) (cdr range))))
    (and hunk (cl-position hunk (claude-code-ide-review-view-hunks view)
                           :test (lambda (a b)
                                   (equal (claude-code-ide-review-hunk-id a)
                                          (claude-code-ide-review-hunk-id b)))))))

(defun claude-code-ide-review--current-hunk (view)
  "Return the hunk struct under VIEW's current difference, or nil."
  (when-let* ((index (claude-code-ide-review-view-hunk view)))
    (nth index (claude-code-ide-review-view-hunks view))))

(defun claude-code-ide-review--header-line (hunk status)
  "Return the header shown above a justification or comment for HUNK."
  (propertize (format "%s  %s" (claude-code-ide-review--hunk-range-string hunk) status)
              'face 'claude-code-ide-review-header))

(defun claude-code-ide-review--fill-claude-buffer (view)
  "Show the justification of VIEW's current hunk in the left bottom window."
  (let* ((dir (claude-code-ide-review-view-project-dir view))
         (hunk (claude-code-ide-review--current-hunk view))
         (status (and hunk (claude-code-ide-review-hunk-status dir hunk 'claude
                                                               (claude-code-ide-review-view-hunks view)))))
    (with-current-buffer (claude-code-ide-review-view-claude-buffer view)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (cond
         ((null hunk)
          (insert (propertize "No hunk matches this difference; refresh with g"
                              'face 'claude-code-ide-review-placeholder)))
         ((eq (car status) 'ok)
          (insert (claude-code-ide-review--header-line hunk "ok") "\n"
                  (claude-code-ide-review-note-text (cdr status))))
         (t
          (insert (claude-code-ide-review--header-line hunk (symbol-name (car status))) "\n"
                  (propertize (claude-code-ide-review--placeholder-text)
                              'face 'claude-code-ide-review-placeholder))
          (when (eq (car status) 'stale)
            (insert "\n\n" (propertize "Earlier justification: " 'face 'claude-code-ide-review-header)
                    (claude-code-ide-review-note-text (cdr status))))))
        (goto-char (point-min))))))

(defun claude-code-ide-review--save-comment (view)
  "Store the comment window's text as the user note of the hunk it edits."
  (when-let* ((hunk (claude-code-ide-review-view-comment-hunk view))
              (buffer (claude-code-ide-review-view-user-buffer view))
              ((buffer-live-p buffer)))
    (let ((dir (claude-code-ide-review-view-project-dir view))
          (text (with-current-buffer buffer (buffer-string))))
      (if (string-blank-p text)
          (claude-code-ide-review-remove-note dir (claude-code-ide-review-hunk-id hunk) 'user)
        (claude-code-ide-review-put-note dir hunk 'user text)))))

(defun claude-code-ide-review--fill-user-buffer (view)
  "Load VIEW's current hunk's comment into the comment window.
The previous hunk's text is saved first.  Without a matching hunk the
window is read-only and says so."
  (claude-code-ide-review--save-comment view)
  (let* ((dir (claude-code-ide-review-view-project-dir view))
         (hunk (claude-code-ide-review--current-hunk view))
         (note (and hunk (claude-code-ide-review-get-note
                          dir (claude-code-ide-review-hunk-id hunk) 'user))))
    (setf (claude-code-ide-review-view-comment-hunk view) hunk)
    (with-current-buffer (claude-code-ide-review-view-user-buffer view)
      (let ((inhibit-modification-hooks t)
            (inhibit-read-only t))
        (erase-buffer)
        (if hunk
            (progn
              (setq buffer-read-only nil
                    header-line-format (list " " (claude-code-ide-review--header-line hunk "your comment")))
              (when note (insert (claude-code-ide-review-note-text note))))
          (setq header-line-format nil)
          (insert (propertize "No hunk matches this difference" 'face 'claude-code-ide-review-placeholder))
          (setq buffer-read-only t))
        (set-buffer-modified-p nil)
        (goto-char (point-max))))))

(defun claude-code-ide-review--comment-changed (_beg _end _len)
  "Save the comment window after every change; `after-change-functions'."
  (when-let* ((view claude-code-ide-review--view)
              ((eq (current-buffer) (claude-code-ide-review-view-user-buffer view))))
    (claude-code-ide-review--save-comment view)))

(defun claude-code-ide-review--update-side-windows (view)
  "Point VIEW's hunk at the current difference and refill both bottom windows."
  (setf (claude-code-ide-review-view-hunk view)
        (when-let* ((n (claude-code-ide-review--current-difference view)))
          (claude-code-ide-review--hunk-for-difference view n)))
  (claude-code-ide-review--fill-claude-buffer view)
  (claude-code-ide-review--fill-user-buffer view))

(defun claude-code-ide-review--on-select ()
  "`ediff-select-hook' member: follow the difference when the session is ours."
  (when-let* ((view claude-code-ide-review--view)
              ((eq (current-buffer) (claude-code-ide-review-view-control view))))
    (claude-code-ide-review--update-side-windows view)))

;;; View: session lifecycle

(defun claude-code-ide-review--on-ediff-startup (view)
  "Finish VIEW's setup inside its new ediff control buffer."
  (setf (claude-code-ide-review-view-control view) (current-buffer))
  ;; On a text terminal ediff replaces the setup function with its plain
  ;; layout before building the windows, so set ours in the control
  ;; buffer for later rebuilds and lay the windows out now
  (setq-local ediff-window-setup-function #'claude-code-ide-review--setup-windows)
  (setq-local ediff-split-window-function #'split-window-horizontally)
  (claude-code-ide-review--setup-windows ediff-buffer-A ediff-buffer-B nil (current-buffer))
  (setq-local ediff-after-quit-hook-internal
              (cons (lambda () (claude-code-ide-review--after-quit view))
                    ediff-after-quit-hook-internal))
  (dolist (key '("e" "f" "o" "c"))
    (define-key ediff-mode-map key (lookup-key claude-code-ide-review-mode-map key)))
  (add-hook 'ediff-select-hook #'claude-code-ide-review--on-select)
  (add-hook 'ediff-after-setup-windows-hook #'claude-code-ide-review--after-setup-windows)
  (add-hook 'window-scroll-functions #'claude-code-ide-review--on-scroll)
  (with-current-buffer (claude-code-ide-review-view-user-buffer view)
    (add-hook 'after-change-functions #'claude-code-ide-review--comment-changed nil t))
  (claude-code-ide-review--update-side-windows view)
  (when (> ediff-number-of-differences 0)
    (ediff-jump-to-difference 1)))

(defun claude-code-ide-review--start-ediff (view file)
  "Start VIEW's ediff session on FILE and fill the bottom windows."
  (let* ((dir (claude-code-ide-review-view-project-dir view))
         (old (claude-code-ide-review--old-buffer dir file))
         ;; NOWARN: a buffer left behind by an earlier review whose file
         ;; changed since must not raise a question; revert it instead
         (new (find-file-noselect (claude-code-ide-review--file-path dir file) t)))
    (with-current-buffer new
      (when (and (not (buffer-modified-p))
                 (not (verify-visited-file-modtime)))
        (revert-buffer t t t)))
    (setf (claude-code-ide-review-view-file view) file
          (claude-code-ide-review-view-hunks view) (claude-code-ide-review-hunks dir file)
          (claude-code-ide-review-view-hunk view) nil
          (claude-code-ide-review-view-comment-hunk view) nil
          (claude-code-ide-review-view-old-buffer view) old
          (claude-code-ide-review-view-file-buffer view) new)
    (let ((ediff-window-setup-function #'claude-code-ide-review--setup-windows)
          (ediff-split-window-function #'split-window-horizontally))
      (ediff-buffers old new
                     (list (lambda () (claude-code-ide-review--on-ediff-startup view)))))
    (claude-code-ide-review--watch-file view)
    (unless (claude-code-ide-review-view-hunks view)
      (if-let* ((next (car (remove file (claude-code-ide-review-changed-files dir)))))
          (message "%s has no changes left; %s does (o to switch)" file next)
        (message "%s has no changes left" file)))))

(defun claude-code-ide-review--stop-ediff (view)
  "End VIEW's ediff session without asking.  The real file buffer is kept."
  (when-let* ((control (claude-code-ide-review-view-control view))
              ((buffer-live-p control)))
    (claude-code-ide-review--save-comment view)
    (with-current-buffer control
      (ediff-really-quit nil))))

(defun claude-code-ide-review--after-quit (view)
  "Clean up after VIEW's ediff session ended, by `q' or by our commands.
Runs from the control buffer's `ediff-after-quit-hook-internal', after
ediff's own cleanup.  While VIEW is switching files only the baseline
buffer goes; otherwise the view closes and the windows are restored."
  (setf (claude-code-ide-review-view-control view) nil)
  (when-let* ((old (claude-code-ide-review-view-old-buffer view))
              ((buffer-live-p old)))
    (kill-buffer old))
  (unless (claude-code-ide-review-view-switching view)
    (remove-hook 'ediff-select-hook #'claude-code-ide-review--on-select)
    (remove-hook 'ediff-after-setup-windows-hook #'claude-code-ide-review--after-setup-windows)
    (remove-hook 'window-scroll-functions #'claude-code-ide-review--on-scroll)
    (claude-code-ide-review--unwatch view)
    (dolist (buffer (list (claude-code-ide-review-view-claude-buffer view)
                          (claude-code-ide-review-view-user-buffer view)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (when (eq claude-code-ide-review--view view)
      (setq claude-code-ide-review--view nil))
    (pcase (claude-code-ide-review-view-restore view)
      (`(tab . ,name)
       (when (fboundp 'tab-bar-close-tab-by-name)
         (tab-bar-close-tab-by-name name)))
      (`(winconf . ,configuration)
       (set-window-configuration configuration)))))

(defun claude-code-ide-review--create-view (project-dir)
  "Create the view struct for PROJECT-DIR and claim a tab or the frame.
With `tab-bar-mode' on, the review lives in a new tab named
claude-review; otherwise the current window configuration is saved for
quit."
  (let* ((restore (if (bound-and-true-p tab-bar-mode)
                      (progn
                        (tab-bar-new-tab)
                        (tab-bar-rename-tab "claude-review")
                        (cons 'tab "claude-review"))
                    (cons 'winconf (current-window-configuration))))
         (view (make-claude-code-ide-review-view
                :project-dir (claude-code-ide-review--normalize-dir project-dir)
                :restore restore)))
    (setf (claude-code-ide-review-view-claude-buffer view)
          (claude-code-ide-review--side-buffer view "claude" 'claude-code-ide-review-mode)
          (claude-code-ide-review-view-user-buffer view)
          (claude-code-ide-review--side-buffer view "user" 'claude-code-ide-review-comment-mode))
    (setq claude-code-ide-review--view view)))

(defun claude-code-ide-review--show-file (view file)
  "Show FILE in VIEW, ending the ediff session of the previous file first."
  (if (claude-code-ide-review-view-control view)
      (progn
        (setf (claude-code-ide-review-view-switching view) t)
        (unwind-protect
            (claude-code-ide-review--stop-ediff view)
          (setf (claude-code-ide-review-view-switching view) nil))
        (claude-code-ide-review--start-ediff view file))
    (claude-code-ide-review--start-ediff view file)))

;;; View: scroll sync between the diff windows

(defvar claude-code-ide-review--syncing nil
  "Non-nil while one diff window is being moved to follow the other.")

(defun claude-code-ide-review--line-position (line)
  "Return the position of the start of LINE (1-based) in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (point)))

(defun claude-code-ide-review--map-line (hunks line from)
  "Return the line in the other file matching LINE in the FROM file.
FROM is `old' (the baseline, ediff buffer A) or `new' (the working
file, ediff buffer B).  HUNKS are the file's hunks in file order.
Before the first hunk lines match one to one; a line inside a hunk maps
to the hunk's first line on the other side; after each hunk the offset
grows by the hunk's size difference."
  (let ((delta 0)
        (result nil))
    (dolist (hunk hunks)
      (unless result
        (let* ((old-p (eq from 'old))
               (start (if old-p (claude-code-ide-review-hunk-old-start hunk)
                        (claude-code-ide-review-hunk-new-start hunk)))
               (count (if old-p (claude-code-ide-review-hunk-old-count hunk)
                        (claude-code-ide-review-hunk-new-count hunk)))
               (other-start (if old-p (claude-code-ide-review-hunk-new-start hunk)
                              (claude-code-ide-review-hunk-old-start hunk)))
               (other-count (if old-p (claude-code-ide-review-hunk-new-count hunk)
                              (claude-code-ide-review-hunk-old-count hunk))))
          (cond
           ;; A side of count 0 owns no lines: git reports the line before
           ;; the gap, which lies before the hunk and maps by offset
           ((or (< line start) (and (= count 0) (= line start)))
            (setq result (+ line delta)))
           ((<= line (claude-code-ide-review--range-end start count))
            (setq result (max 1 other-start)))
           (t
            (setq delta (+ delta (- other-count count))))))))
    (max 1 (or result (+ line delta)))))

(defun claude-code-ide-review--on-scroll (window start)
  "`window-scroll-functions' member: keep ediff windows A and B aligned.
START is the position WINDOW is about to show first; inside this hook
`window-start' still returns the old value, so START must be used.

The other window's start is forced, so redisplay keeps it and moves
that window's point into view when it was off screen.  An optional
start would be dropped whenever the point was elsewhere, which is the
case as soon as only one window has been scrolled.  Redisplay then runs
this hook for the moved window with the start just set; the window
parameter `claude-code-ide-review-synced-start' marks that start so it
is not mapped back, which would snap the scrolled window to a hunk
boundary."
  (let ((synced (window-parameter window 'claude-code-ide-review-synced-start)))
    (set-window-parameter window 'claude-code-ide-review-synced-start nil)
    (when-let* ((view claude-code-ide-review--view)
                ((not claude-code-ide-review--syncing))
                ((not (eql synced start)))
                (control (claude-code-ide-review-view-control view))
                ((buffer-live-p control)))
      (let* ((window-a (buffer-local-value 'ediff-window-A control))
             (window-b (buffer-local-value 'ediff-window-B control))
             (other (cond ((eq window window-a) window-b)
                          ((eq window window-b) window-a))))
        (when (and (window-live-p other) (window-live-p window))
          (let* ((claude-code-ide-review--syncing t)
                 (line (with-current-buffer (window-buffer window)
                         (line-number-at-pos start)))
                 (target (claude-code-ide-review--map-line
                          (claude-code-ide-review-view-hunks view)
                          line
                          (if (eq window window-a) 'old 'new)))
                 (position (with-current-buffer (window-buffer other)
                             (claude-code-ide-review--line-position target))))
            (unless (= position (window-start other))
              (set-window-parameter other 'claude-code-ide-review-synced-start position)
              (set-window-start other position))))))))

;;; View: navigation

(defun claude-code-ide-review-select-hunk (index)
  "Make hunk INDEX of the open view current by selecting its ediff difference."
  (let* ((view (claude-code-ide-review--view-check))
         (hunk (nth index (claude-code-ide-review-view-hunks view)))
         (count (claude-code-ide-review--difference-count view)))
    (when hunk
      (let ((start (claude-code-ide-review-hunk-new-start hunk))
            (end (claude-code-ide-review--range-end (claude-code-ide-review-hunk-new-start hunk)
                                                    (claude-code-ide-review-hunk-new-count hunk))))
        (cl-loop for n from 0 below count
                 for range = (claude-code-ide-review--difference-lines view n)
                 when (> (claude-code-ide-review--overlap start end (car range) (cdr range)) 0)
                 do (with-current-buffer (claude-code-ide-review-view-control view)
                      (ediff-jump-to-difference (1+ n)))
                 and return n)))))

(defun claude-code-ide-review-next-hunk ()
  "Select the next difference in the open review."
  (interactive)
  (let ((view (claude-code-ide-review--view-check)))
    (with-current-buffer (claude-code-ide-review-view-control view)
      (ediff-next-difference))))

(defun claude-code-ide-review-previous-hunk ()
  "Select the previous difference in the open review."
  (interactive)
  (let ((view (claude-code-ide-review--view-check)))
    (with-current-buffer (claude-code-ide-review-view-control view)
      (ediff-previous-difference))))

(defun claude-code-ide-review-comment ()
  "Move to the comment window of the open review."
  (interactive)
  (let* ((view (claude-code-ide-review--view-check))
         (window (get-buffer-window (claude-code-ide-review-view-user-buffer view))))
    (if (window-live-p window)
        (select-window window)
      (user-error "The comment window is not shown"))))

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

;;; View: commands

(defun claude-code-ide-review--read-changed-file (project-dir)
  "Ask for one of PROJECT-DIR's changed files."
  (let ((files (claude-code-ide-review-changed-files project-dir)))
    (unless files
      (user-error "No changes since the baseline"))
    (completing-read "Review file: " files nil t)))

;;;###autoload
(defun claude-code-ide-review-open (&optional file)
  "Open the review on FILE, or on the first changed file.
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
      view)))

(defun claude-code-ide-review-select-file ()
  "Show another changed file in the open view."
  (interactive)
  (let ((view (claude-code-ide-review--view-check)))
    (claude-code-ide-review-open
     (claude-code-ide-review--read-changed-file
      (claude-code-ide-review-view-project-dir view)))))

(defun claude-code-ide-review-refresh ()
  "Recompute the differences of the open view from the file on disk.
The real file's buffer is reverted when it has no unsaved changes, the
hunks and ediff's differences are recomputed, and the bottom windows
follow the difference that is current afterwards."
  (interactive)
  (let* ((view (claude-code-ide-review--view-check))
         (dir (claude-code-ide-review-view-project-dir view))
         (file (claude-code-ide-review-view-file view))
         (file-buffer (claude-code-ide-review-view-file-buffer view)))
    (claude-code-ide-review--save-comment view)
    (when (and (buffer-live-p file-buffer)
               (not (buffer-modified-p file-buffer))
               (not (verify-visited-file-modtime file-buffer)))
      (with-current-buffer file-buffer
        (revert-buffer t t t)))
    (setf (claude-code-ide-review-view-hunks view) (claude-code-ide-review-hunks dir file))
    (with-current-buffer (claude-code-ide-review-view-control view)
      (ediff-update-diffs))
    (claude-code-ide-review--update-side-windows view)
    (unless (claude-code-ide-review-view-hunks view)
      (if-let* ((next (car (remove file (claude-code-ide-review-changed-files dir)))))
          (message "%s has no changes left; %s does (o to switch)" file next)
        (message "%s has no changes left" file)))))

;;;###autoload
(defun claude-code-ide-review-quit ()
  "Close the review and restore the windows or tab it replaced."
  (interactive)
  (when-let* ((view claude-code-ide-review--view))
    (if (claude-code-ide-review-view-control view)
        (claude-code-ide-review--stop-ediff view)
      ;; No ediff session (it failed to start): close the view by hand
      (claude-code-ide-review--after-quit view))))
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
is set.  Enables the MCP tools server, which the tools and the slash
command are served from.  Safe to call more than once."
  (interactive)
  (setq claude-code-ide-enable-mcp-server t)
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
