// One walk through nugitea as its users would take it, against the state
// seed.json sets up: browse the seeded owners and repos, push code over
// smart HTTP with a token, read it back in the web UI and the REST API,
// check that a private repo stays private, and delete a repo.
//
// The tests run in order and build on each other: the server's state
// carries over from one to the next, only the browser is reset.

const api = Cypress.expose('apiUrl')
const work = Cypress.expose('workDir')
const clone = `${work}/hello`

let tokens

/** A smart-HTTP remote for `repo`, authenticating with `token` as the password. */
const remote = (repo, user, token) =>
  `${api.replace('://', `://${user}:${encodeURIComponent(token)}@`)}/${repo}.git`

const as = (user) => ({ Authorization: `token ${tokens[user]}` })

describe('nugitea, end to end', () => {
  before(() => {
    cy.readFile(Cypress.expose('seedOutput')).then((seed) => {
      tokens = seed.tokens
    })
  })

  it('lists the seeded public repos, but not private ones', () => {
    cy.visit('/')
    cy.location('pathname').should('eq', '/repos')
    cy.contains('h2', 'Repositories')
    cy.contains('a', 'alice/hello')
    cy.contains('a', 'acme/api')
    cy.contains('alice/secret').should('not.exist')
  })

  it('shows an org and its empty repo', () => {
    cy.visit('/acme')
    cy.contains('h2', 'acme')
    cy.contains('a', 'api').click()
    cy.location('pathname').should('eq', '/acme/api')
    cy.contains('This repository has no branches yet.')
  })

  it('pushes a commit over smart HTTP, refusing a bad token', () => {
    const git = (...args) => cy.task('git', { args, cwd: clone })

    cy.task('emptyDir', clone)
    git('init', '-q', '-b', 'main')
    cy.writeFile(`${clone}/README.md`, '# Hello\n\nPushed by Cypress.\n')
    cy.writeFile(`${clone}/src/main.txt`, 'hello from a subdirectory\n')
    git('add', '.')
    git('-c', 'user.name=Alice', '-c', 'user.email=alice@example.com', 'commit', '-q', '-m', 'Add README')

    cy.task('git', {
      args: ['push', remote('alice/hello', 'alice', 'not-a-token'), 'main'],
      cwd: clone,
      allowFailure: true
    }).then(({ code, stderr }) => {
      expect(code).not.to.eq(0)
      expect(stderr).to.match(/401|Authentication failed/)
    })

    git('push', '-q', remote('alice/hello', 'alice', tokens.alice), 'main')
  })

  it('shows the pushed files in the web UI', () => {
    // The bare repo URL redirects to its default branch.
    cy.visit('/alice/hello')
    cy.location('pathname').should('eq', '/alice/hello/tree/main')

    cy.contains('a', 'src').click()
    cy.location('pathname').should('eq', '/alice/hello/tree/main/src')
    cy.contains('a', 'main.txt')

    cy.visit('/alice/hello/tree/main')
    cy.contains('a', 'README.md').click()
    cy.location('pathname').should('eq', '/alice/hello/blob/main/README.md')
    cy.contains('pre', 'Pushed by Cypress.')
  })

  it('reports the push through the REST API', () => {
    cy.request(`${api}/api/v1/repos/alice/hello/branches`)
      .its('body')
      .should((branches) => {
        expect(branches.map((b) => b.name)).to.deep.eq(['main'])
        expect(branches[0].commit.message).to.eq('Add README')
      })

    cy.request(`${api}/api/v1/repos/alice/hello/raw/src/main.txt`)
      .its('body')
      .should('eq', 'hello from a subdirectory\n')
  })

  it('keeps a private repo private', () => {
    const secret = `${api}/api/v1/repos/alice/secret`
    cy.request({ url: secret, failOnStatusCode: false }).its('status').should('eq', 404)
    cy.request({ url: secret, headers: as('bob'), failOnStatusCode: false })
      .its('status')
      .should('eq', 404)
    cy.request({ url: secret, headers: as('alice') }).its('status').should('eq', 200)

    cy.visit('/alice/secret')
    cy.contains('Not found.')
  })

  it('lets only the owner delete a repo', () => {
    const hello = `${api}/api/v1/repos/alice/hello`
    cy.request({ method: 'DELETE', url: hello, headers: as('bob'), failOnStatusCode: false })
      .its('status')
      .should('eq', 403)
    cy.request({ method: 'DELETE', url: hello, headers: as('alice') })
      .its('status')
      .should('eq', 204)

    cy.visit('/repos')
    cy.contains('a', 'acme/api')
    cy.contains('alice/hello').should('not.exist')
  })
})
