/** The signed-in user's login, or null: loaded once per page load (SSR,
 * with the browser's cookie) and shared by every component. */
export async function useViewer() {
  const viewer = useState<string | null>('viewer', () => null)
  await useAsyncData('viewer', async () => {
    const data = await graphqlRequest<{ viewer: { login: string } | null }>(/* GraphQL */ `
      query {
        viewer {
          login
        }
      }
    `)
    viewer.value = data.viewer?.login ?? null
    return viewer.value
  })
  return viewer
}

/** Signs in or out through the app tier's /-/session, then reloads the page
 * so everything renders as the new user. */
export async function signIn(login: string, password: string, then: string) {
  await $fetch('/-/session', { method: 'POST', body: { login, password } })
  window.location.assign(then)
}

export async function signOut() {
  await $fetch('/-/session', { method: 'DELETE' })
  window.location.reload()
}
