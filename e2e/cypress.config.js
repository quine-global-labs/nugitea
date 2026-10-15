import { spawnSync } from 'node:child_process'
import { mkdirSync, rmSync } from 'node:fs'
import { defineConfig } from 'cypress'

// run.sh starts the servers and passes where they are through the
// environment: the Nuxt frontend (baseUrl), nugitea's HTTP port (apiUrl),
// the tokens `mix nugitea seed` printed (seedOutput), and scratch space for
// git working copies (workDir).
export default defineConfig({
  expose: {
    apiUrl: process.env.NUGITEA_E2E_API_URL,
    seedOutput: process.env.NUGITEA_E2E_SEED_OUTPUT,
    workDir: process.env.NUGITEA_E2E_WORK_DIR
  },
  e2e: {
    baseUrl: process.env.NUGITEA_E2E_WEB_URL,
    specPattern: 'cypress/e2e/**/*.cy.js',
    supportFile: false,
    video: false,
    screenshotsFolder: 'cypress/screenshots',
    setupNodeEvents(on) {
      on('task', {
        // `git ARGS` in `cwd`, without a shell. Fails the test on a non-zero
        // exit unless `allowFailure`; resolves to { code, stdout, stderr }.
        git({ args, cwd, allowFailure = false }) {
          const r = spawnSync('git', args, { cwd, encoding: 'utf8' })
          if (r.error) throw r.error
          if (r.status !== 0 && !allowFailure) {
            throw new Error(`git ${args.join(' ')} exited ${r.status}: ${r.stderr}`)
          }
          return { code: r.status, stdout: r.stdout, stderr: r.stderr }
        },
        emptyDir(dir) {
          rmSync(dir, { recursive: true, force: true })
          mkdirSync(dir, { recursive: true })
          return null
        }
      })
    }
  }
})
