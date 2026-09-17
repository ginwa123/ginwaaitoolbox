<template>
  <div class="login-wrap">
    <form class="login-card" @submit.prevent="onSubmit">
      <h1>Nalar Login</h1>
      <p v-if="authDisabled" class="muted">
        Auth is disabled on this server — you should not see this page.
      </p>
      <label>
        Email
        <input v-model="email" type="email" autocomplete="username" required :disabled="busy" />
      </label>
      <label>
        Password
        <input
          v-model="password"
          type="password"
          autocomplete="current-password"
          required
          :disabled="busy"
        />
      </label>
      <p v-if="error" class="error">{{ error }}</p>
      <button type="submit" :disabled="busy">{{ busy ? 'Signing in…' : 'Sign in' }}</button>
    </form>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'

const route = useRoute()
const router = useRouter()
const email = ref('')
const password = ref('')
const error = ref('')
const busy = ref(false)
const authDisabled = ref(false)

function redirectTarget(): string {
  const r = route.query.redirect
  return typeof r === 'string' && r.startsWith('/') ? r : '/app'
}

onMounted(async () => {
  // Already logged in? Skip the form (deep-linkable ?redirect= is honored).
  try {
    const res = await fetch('/api/auth/me', { credentials: 'same-origin' })
    if (res.ok) {
      const data = await res.json().catch(() => null)
      if (data && (data.authenticated === true || data.auth_enabled === false)) {
        if (data.auth_enabled === false) authDisabled.value = true
        else {
          await router.replace(redirectTarget())
          return
        }
      }
    }
  } catch {
    /* offline — show the form */
  }
})

async function onSubmit() {
  error.value = ''
  busy.value = true
  try {
    const res = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({ email: email.value.trim(), password: password.value }),
    })
    if (!res.ok) {
      error.value = 'Invalid email or password'
      return
    }
    await router.replace(redirectTarget())
  } catch {
    error.value = 'Network error — is the server running?'
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.login-wrap {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100vh;
}
.login-card {
  display: flex;
  flex-direction: column;
  gap: 12px;
  width: 320px;
  padding: 24px;
  border: 1px solid var(--border, #282727);
  border-radius: 12px;
}
.login-card h1 {
  font-size: 20px;
  margin: 0;
}
.login-card label {
  display: flex;
  flex-direction: column;
  gap: 6px;
  font-size: 13px;
}
.login-card input {
  padding: 8px 10px;
  border-radius: 8px;
  border: 1px solid var(--border, #282727);
  background: transparent;
  color: inherit;
}
.error {
  color: #e5484d;
  font-size: 13px;
  margin: 0;
}
.muted {
  font-size: 13px;
  opacity: 0.7;
  margin: 0;
}
button {
  padding: 9px 12px;
  border-radius: 8px;
  cursor: pointer;
}
</style>
