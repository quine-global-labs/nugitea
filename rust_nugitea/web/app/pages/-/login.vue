<script setup lang="ts">
// /-/login: account names can't start with "-", so this can't be a repo.
const route = useRoute()
const login = ref('')
const password = ref('')
const error = ref('')
const busy = ref(false)

// Only a path on this site: never an absolute URL from the query string.
const then = computed(() => {
  const t = route.query.then
  return typeof t === 'string' && t.startsWith('/') && !t.startsWith('//') ? t : '/repos'
})

async function submit() {
  busy.value = true
  error.value = ''
  try {
    await signIn(login.value, password.value, then.value)
  } catch {
    error.value = 'Wrong login or password.'
    busy.value = false
  }
}
</script>

<template>
  <div class="container">
    <h2>Sign in</h2>
    <form class="sign-in" @submit.prevent="submit">
      <label>
        Login
        <input v-model="login" name="login" autocomplete="username" required autofocus />
      </label>
      <label>
        Password
        <input v-model="password" name="password" type="password" autocomplete="current-password" required />
      </label>
      <p v-if="error" class="error" role="alert">{{ error }}</p>
      <button type="submit" :disabled="busy">Sign in</button>
    </form>
  </div>
</template>
