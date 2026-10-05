// Tiny external store describing "a navigation is in flight". It lets any
// component show instant feedback (top progress bar, highlighted tab/menu
// item, dimmed content) between the click and the moment the next page is on
// screen. It never performs navigation itself and holds no user data.

export type NavigationState = { active: boolean; path: string | null };

const IDLE: NavigationState = { active: false, path: null };
let state: NavigationState = IDLE;
const listeners = new Set<() => void>();

function set(next: NavigationState) {
  state = next;
  listeners.forEach((l) => l());
}

export function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export const getSnapshot = () => state;
export const getServerSnapshot = () => IDLE;

// Call right before navigating (a link click is picked up automatically by
// <NavigationProgress/>; programmatic router.push() calls should call this).
// Ignores external URLs and navigations to the page you are already on.
export function startNavigation(href: string) {
  if (typeof window === "undefined") return;
  let url: URL;
  try {
    url = new URL(href, window.location.href);
  } catch {
    return;
  }
  if (url.origin !== window.location.origin) return;
  if (url.pathname + url.search === window.location.pathname + window.location.search) return;
  set({ active: true, path: url.pathname });
}

export function endNavigation() {
  if (state.active) set(IDLE);
}
