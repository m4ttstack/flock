import Foundation

/// The repo's main checkout for a folder anywhere in it, a linked worktree
/// included, read off the files git leaves on disk rather than by running git:
/// it is asked on the way to creating a tab, so it has to cost a handful of
/// stat calls, not a process launch.
///
/// A `.git` directory marks a main checkout. A `.git` file marks a linked
/// worktree or a submodule: its `gitdir` holds a `commondir` pointing at the
/// main checkout's `.git` for a worktree, and none for a submodule, which is
/// its own only checkout.
public enum MainCheckout {
    public static func resolve(from folder: String) -> String? {
        var directory = URL(fileURLWithPath: folder, isDirectory: true).standardized
        while true {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? directory.path : checkout(linkedBy: dotGit, from: directory)
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
    }

    private static func checkout(linkedBy dotGitFile: URL, from directory: URL) -> String? {
        let prefix = "gitdir:"
        guard let text = try? String(contentsOf: dotGitFile, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix(prefix)
        else { return nil }
        let gitDir = path(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces), from: directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return checkout(ofPruned: gitDir)
        }
        guard let common = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) else {
            return directory.path
        }
        let commonDir = path(common.trimmingCharacters(in: .whitespacesAndNewlines), from: gitDir)
        guard commonDir.lastPathComponent == ".git" else { return nil }
        return commonDir.deletingLastPathComponent().path
    }

    /// A worktree whose gitdir is gone: git prunes `<repo>/.git/worktrees/<name>`
    /// when the worktree is removed or moved away (rt moves them to a trash
    /// folder), and a pane can still sit in what is left. Its main checkout
    /// is still `<repo>` while that checkout exists; anything else is no
    /// repository, never the leftover folder itself.
    private static func checkout(ofPruned gitDir: URL) -> String? {
        let worktrees = gitDir.deletingLastPathComponent()
        let dotGit = worktrees.deletingLastPathComponent()
        guard worktrees.lastPathComponent == "worktrees", dotGit.lastPathComponent == ".git" else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return dotGit.deletingLastPathComponent().path
    }

    /// Lexical only: resolving symlinks would hand back `/private/var` for a
    /// folder the pane reports as `/var`.
    private static func path(_ raw: String, from base: URL) -> URL {
        let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw, isDirectory: true) : base.appendingPathComponent(raw, isDirectory: true)
        return url.standardized
    }
}
