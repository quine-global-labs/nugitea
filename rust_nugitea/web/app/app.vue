<script setup lang="ts">
const viewer = await useViewer()
const route = useRoute()
</script>

<template>
  <header class="site-header">
    <NuxtLink to="/repos">nugitea</NuxtLink>
    <span v-if="viewer" class="viewer">
      {{ viewer }}
      <button type="button" class="link-button" @click="signOut()">Sign out</button>
    </span>
    <NuxtLink v-else-if="route.path !== '/-/login'" :to="{ path: '/-/login', query: { then: route.fullPath } }">
      Sign in
    </NuxtLink>
  </header>
  <NuxtPage />
</template>
