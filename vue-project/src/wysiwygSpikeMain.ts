/**
 * Dev-only entry point for the Phase-0 WYSIWYG spike
 * (`.claude/plans/live-preview-editing-plan.md`). Reachable only via
 * `bun run dev` -> /wysiwyg-spike.html — `vite build` only processes
 * `index.html` by default, so this never ships in the embedded production
 * bundle Rust's `build.rs` compiles into the app.
 */
import { createApp } from 'vue'
import WysiwygEditor from './editor/WysiwygEditor.vue'

createApp(WysiwygEditor).mount('#app')
