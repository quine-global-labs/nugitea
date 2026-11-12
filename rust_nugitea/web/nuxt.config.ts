// https://nuxt.com/docs/api/configuration/nuxt-config
export default defineNuxtConfig({
  compatibilityDate: '2025-07-15',
  devtools: { enabled: true },
  css: ['~/assets/main.css'],
  runtimeConfig: {
    // Server-only: the app tier, for SSR-time GraphQL and for the proxy
    // routes in server/routes/ (/graphql, /-/session). Container-to-
    // container in Docker Compose, so the internal service name.
    appUrl: 'http://127.0.0.1:3080',
    graphqlUrl: 'http://127.0.0.1:3080/graphql',
    public: {
      // Client-visible: where the browser sends GraphQL. Same-origin by
      // default, so the session cookie goes with it: in production nginx
      // sends /graphql to the app tier, elsewhere this server proxies it.
      graphqlUrl: '/graphql'
    }
  }
})
