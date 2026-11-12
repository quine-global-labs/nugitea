import type { H3Event } from 'h3'

/** Hands the request to the app tier (runtimeConfig.appUrl), cookies and
 * all, and its response, Set-Cookie included, back to the browser. For
 * when nothing in front (nginx, in production) routes these paths to the
 * app tier itself: local dev and the e2e suite. */
export function proxyToAppTier(event: H3Event) {
  const { appUrl } = useRuntimeConfig(event)
  return proxyRequest(event, appUrl + event.path)
}
