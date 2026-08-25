//! Markdown to HTML conversion. This is the "backend" the web UI talks to.

use ammonia::Builder;
use pulldown_cmark::{html, Options, Parser};
use std::sync::OnceLock;

fn options() -> Options {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_FOOTNOTES);
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TASKLISTS);
    options.insert(Options::ENABLE_SMART_PUNCTUATION);
    options.insert(Options::ENABLE_HEADING_ATTRIBUTES);
    options
}

/// Allow-list sanitiser, widened to keep everything this renderer itself emits.
///
/// Built once: the preview re-renders on every keystroke.
fn sanitizer() -> &'static Builder<'static> {
    static SANITIZER: OnceLock<Builder<'static>> = OnceLock::new();
    SANITIZER.get_or_init(|| {
        let mut builder = Builder::new();
        // Anchor targets: `{#custom-id}` headings and footnote definitions.
        // `class` carries the footnote markers and, later, syntax highlighting.
        builder.add_generic_attributes(["id", "class"]);
        // Task lists render as disabled checkboxes.
        builder.add_tags(["input"]);
        builder.add_tag_attributes("input", ["type", "checked", "disabled"]);
        builder
    })
}

/// Renders a Markdown document to an HTML fragment.
///
/// The result is sanitised before it leaves this function. CommonMark passes raw HTML
/// straight through, so without this a note containing `<img src=x onerror=...>` would run
/// script in whichever web view displayed it — and notes are no longer only ever authored by
/// hand, now that agents and MCP clients write them too.
pub fn render_markdown(markdown: &str) -> String {
    let parser = Parser::new_ext(markdown, options());
    let mut out = String::with_capacity(markdown.len() * 3 / 2);
    html::push_html(&mut out, parser);
    sanitizer().clean(&out).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_headings_and_emphasis() {
        let html = render_markdown("# Title\n\nsome **bold** text");
        assert!(html.contains("<h1>Title</h1>"));
        assert!(html.contains("<strong>bold</strong>"));
    }

    #[test]
    fn renders_gfm_extensions() {
        let html = render_markdown("- [x] done\n- [ ] todo\n\n~~gone~~\n");
        assert!(html.contains("type=\"checkbox\""));
        assert!(html.contains("<del>gone</del>"));
    }

    #[test]
    fn renders_tables() {
        let html = render_markdown("| a | b |\n| - | - |\n| 1 | 2 |\n");
        assert!(html.contains("<table>"));
    }

    #[test]
    fn strips_script_tags() {
        let html = render_markdown("before\n\n<script>alert(1)</script>\n\nafter");
        assert!(!html.contains("<script"), "{html}");
        assert!(!html.contains("alert(1)"), "{html}");
        assert!(html.contains("before"));
        assert!(html.contains("after"));
    }

    #[test]
    fn strips_event_handler_attributes() {
        let html = render_markdown("<img src=x onerror=\"alert(1)\">");
        assert!(!html.contains("onerror"), "{html}");
    }

    #[test]
    fn strips_javascript_urls() {
        let html = render_markdown("[click](javascript:alert(1))");
        assert!(!html.contains("javascript:"), "{html}");
    }

    #[test]
    fn strips_inline_event_handlers_in_raw_html() {
        let html = render_markdown("text <span onmouseover=\"alert(1)\">hover</span> more");
        assert!(!html.contains("onmouseover"), "{html}");
        assert!(html.contains("hover"), "{html}");
    }

    #[test]
    fn keeps_author_supplied_heading_ids() {
        let html = render_markdown("# Title {#custom-id}");
        assert!(html.contains("id=\"custom-id\""), "{html}");
    }

    #[test]
    fn keeps_task_list_checkboxes() {
        let html = render_markdown("- [x] done");
        assert!(html.contains("type=\"checkbox\""), "{html}");
    }

    /// Guards against the sanitiser quietly removing something the preview relies on.
    #[test]
    fn a_full_featured_document_survives_sanitising() {
        let html = render_markdown(
            "# Title\n\n\
             ## Section {#anchor}\n\n\
             Text with **bold**, *italic*, ~~struck~~, `code`, and a [link](https://example.com).\n\n\
             - [x] done\n- [ ] todo\n\n\
             | a | b |\n| - | - |\n| 1 | 2 |\n\n\
             ```rust\nlet x = 1;\n```\n\n\
             > quoted\n\n\
             ![image](https://example.com/i.png)\n\n\
             Footnote[^1]\n\n[^1]: the note\n",
        );

        for expected in [
            "<h1>", "id=\"anchor\"", "<strong>", "<em>", "<del>", "<code>",
            "https://example.com", "type=\"checkbox\"", "<table>", "<th>", "<td>",
            "<pre>", "<blockquote>", "<img", "footnote",
        ] {
            assert!(html.contains(expected), "lost {expected:?} from:\n{html}");
        }
    }

    #[test]
    fn handles_empty_input() {
        assert_eq!(render_markdown(""), "");
    }
}
