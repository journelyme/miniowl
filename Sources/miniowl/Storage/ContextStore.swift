import Foundation

/// File-backed store for the user's personalization context.
///
/// Free-form text store where the user describes their work, projects,
/// taxonomy preferences, and tone preferences. The server
/// appends this to the categorization prompt, so every user gets a
/// customized experience without hardcoding Trung's specifics on the server.
///
/// File: `~/Library/Application Support/miniowl/context.md`
///
/// Design choices:
/// - Markdown extension so TextEdit/VSCode render headings nicely
/// - Read per-request (not cached) — edits take effect on the very next
///   categorize call without any reload button
/// - Size-capped at 2 KB to bound LLM cost and prompt bloat
/// - Control characters stripped at read time (security + prompt safety)
/// - Missing/empty file is legal — server falls back to generic defaults
struct ContextStore {
    let dataDir: URL

    /// Upper bound on context size after trimming. Users often write
    /// several paragraphs of rules, examples, tone preferences — a few
    /// KB is normal. 8 KB covers that comfortably; LLM input cost at
    /// 24 calls/day is ~$0.05/day extra per user = trivial.
    /// Server-side cap (in miniowl_prompts.py) is matched at 8 KB.
    static let maxBytes = 8192

    var fileURL: URL {
        dataDir.appendingPathComponent("context.md")
    }

    // MARK: - Read

    /// Read the context file and return a sanitized string. Returns nil
    /// if the file is missing, unreadable, or contains only placeholder
    /// comments (lines starting with `#` that aren't markdown headings).
    ///
    /// Sanitization:
    /// - Strip ASCII control chars (0x00-0x08, 0x0B, 0x0C, 0x0E-0x1F, 0x7F)
    /// - Cap at `maxBytes` UTF-8 bytes (truncate mid-word if needed)
    /// - Trim outer whitespace
    func read() -> String? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        // Strip control chars except \n, \t, \r
        let cleaned = raw.unicodeScalars.filter { scalar in
            let v = scalar.value
            if v == 0x09 || v == 0x0A || v == 0x0D { return true }
            if v < 0x20 { return false }
            if v == 0x7F { return false }
            return true
        }
        let text = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty { return nil }

        // Cap at maxBytes (UTF-8)
        if text.utf8.count > Self.maxBytes {
            let truncated = String(text.utf8.prefix(Self.maxBytes))
                ?? String(text.prefix(Self.maxBytes))  // fallback if bytes cut mid-codepoint
            return truncated
        }
        return text
    }

    // MARK: - Initialize placeholder

    /// Create a helpful placeholder file on first launch. The placeholder
    /// uses markdown so `open -t` renders it nicely and the user sees
    /// worked examples they can edit.
    func initializeIfMissing() {
        if FileManager.default.fileExists(atPath: fileURL.path) { return }

        let placeholder = """
        # Context for Miniowl categorization

        > EDIT THIS FILE. The example below is a fictional solo founder named
        > Alex — keep the structure, replace every value with your own work.
        > The server reads this on every categorize call (no app reload needed).
        > Max 2 KB. Empty = use defaults; the more specific you are, the
        > sharper the categorization gets.

        ## Who I am

        Solo bootstrapped founder building Acme Ledger, a B2B SaaS for
        small accounting firms. Pre-PMF, ~$2K MRR. Mac-only, terminal-heavy.
        Cold outreach drains me — I need this tool to flag when I'm hiding
        in code instead of talking to users.

        ## My projects

        - Acme Ledger — primary product (acme-ledger repo, acme.com)
        - acme-marketing — landing page + Substack
        - lab-experiments — side learning, NOT a real project

        ## My GTM / outreach activities

        - IndieHackers DMs and posts
        - Twitter/X replies and DMs to other founders
        - User interviews on Zoom, Google Meet
        - Reddit posts in r/SaaS, r/EntrepreneurRideAlong
        - Substack: weekly "Margin Notes" newsletter
        - LinkedIn comments (not posts — too much noise)

        ## My Strategy activities

        - Business: pricing, positioning, lean canvas, escape velocity, MOAT
        - Research: competitors, market trends, funding landscape
        - Reading strategy books (Walling, Maurya, Bush) → Strategy, NOT Learning

        ## My Learning activities

        - Tech tutorials, framework docs, language books
        - Podcasts (founder + tech)
        - General reading not tied to a current decision

        ## My tone preference

        Direct and brutally honest. Don't soften. If I'm 70% Product and 5%
        GTM, say "Joy+Skill trap" — that's the vocabulary I use with myself.
        Use "you" not "we". Slight discomfort is the value; if the summary
        feels comfortable, it's probably wrong. Founder-tribal language is
        fine (Joy+Skill trap, Sweet Spot, 3-circles).

        ## My ideal allocation (weekday targets)

        When writing day_summary, compare against these and flag when off:

        - Product: 35–45% (building is fine, but capped)
        - GTM: 25–35% (the under-done bucket — flag if below 15%)
        - Strategy: 10–15%
        - Learning: 5–10% (flag if >30% on weekday — avoidance)
        - Admin: 5%
        - Operations: 5%
        - Personal: 5–15% on workdays, more on weekends (fine)

        ## Failing patterns (flag explicitly)

        - GTM < 10% → Joy+Skill trap
        - Product > 60% with GTM < 15% → classic avoidance pattern
        - Learning > 30% on weekday → "preparing instead of doing"
        - Personal > 30% during 10am–6pm → probably distracted

        ## Winning patterns (celebrate explicitly)

        - GTM ≥ 25% (outreach, interviews, content shipped)
        - Any user interview completed
        - Strategy + GTM together > Product + Learning
        """
        try? placeholder.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Open in editor

    /// Open the context file in the user's default text editor. Uses
    /// `open -t` so the file opens in whatever editor the user prefers
    /// for .md files.
    func openInEditor() {
        initializeIfMissing()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-t", fileURL.path]
        try? task.run()
    }
}
