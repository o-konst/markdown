import { onBeforeUnmount, ref, toValue, watch, type MaybeRefOrGetter } from 'vue'

/** How far below the top of the viewport a heading still counts as the current one. */
const ACTIVATION_OFFSET = 96

/**
 * Tracks which heading the reader is currently looking at.
 *
 * Deliberately a scroll listener rather than an `IntersectionObserver`: the preview is
 * re-rendered on every keystroke in edit mode, which replaces every heading element, so an
 * observer would have to be torn down and re-attached constantly. Re-querying on demand
 * costs less and has no lifecycle to get wrong.
 */
export function useActiveHeading(
  scroller: MaybeRefOrGetter<HTMLElement | null>,
  ids: MaybeRefOrGetter<string[]>,
) {
  const activeId = ref<string | null>(null)
  let frame = 0

  function measure() {
    frame = 0
    const root = toValue(scroller)
    const headingIds = toValue(ids)
    if (!root || headingIds.length === 0) {
      activeId.value = null
      return
    }

    const threshold = root.getBoundingClientRect().top + ACTIVATION_OFFSET
    // Above the first heading, the first entry is still the best answer.
    let current = headingIds[0] ?? null

    for (const id of headingIds) {
      const heading = root.querySelector(`#${CSS.escape(id)}`)
      if (!heading) continue
      if (heading.getBoundingClientRect().top > threshold) break
      current = id
    }

    activeId.value = current
  }

  function schedule() {
    if (frame !== 0) return
    frame = requestAnimationFrame(measure)
  }

  watch(
    () => toValue(scroller),
    (element, previous) => {
      previous?.removeEventListener('scroll', schedule)
      element?.addEventListener('scroll', schedule, { passive: true })
      schedule()
    },
    { immediate: true, flush: 'post' },
  )

  // Re-measure once the re-rendered headings are in the DOM.
  watch(() => toValue(ids), schedule, { flush: 'post' })

  onBeforeUnmount(() => {
    if (frame !== 0) cancelAnimationFrame(frame)
    toValue(scroller)?.removeEventListener('scroll', schedule)
  })

  return activeId
}
