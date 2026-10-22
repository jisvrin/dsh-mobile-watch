/**
 * dsh-mobile-watch
 *
 * DSH host plugin. On every DSH startup — whatever the launch path (desktop
 * icon, right-click open, taskbar, Win+R, command line, spawned by another
 * program) — the profile loader mounts this bundle and calls apply() once.
 * apply() then fires a detached, hidden PowerShell that:
 *
 *     waits 20 s  →  runs check-mobile.ps1
 *
 * Why the 20 s delay: DSH ends its own `--profile web` instance while booting,
 * so checking immediately would race with that teardown and rebuild a service
 * that is about to be killed again.
 *
 * check-mobile.ps1 is idempotent: if the mobile web service (port + tunnel)
 * is healthy it does nothing at all — no domain change, no email, no log.
 *
 * Cost inside DSH: one appendFileSync + one CreateProcess, then unref().
 * Nothing is kept resident, no timers, no listeners.
 */
import { spawn } from 'node:child_process'
import { appendFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

/** Cordis plugin name. */
export const name = 'dsh-mobile-watch'

/**
 * DSH home. Respects DSH_HOME when the host sets it, otherwise ~/.dsh.
 */
const DSH_HOME = process.env.DSH_HOME || join(homedir(), '.dsh')

/** Script that decides whether the phone service needs rebuilding. */
const CHECK_SCRIPT =
  process.env.DSH_MOBILE_CHECK_SCRIPT || join(DSH_HOME, 'web-service', 'check-mobile.ps1')

/** Small trace file; one line per DSH boot. Safe to delete anytime. */
const TRIGGER_LOG = join(DSH_HOME, 'web-service', 'plugin-trigger.log')

/** Seconds to wait before checking (let DSH finish killing the web instance). */
const DELAY_SECONDS = Number(process.env.DSH_MOBILE_DELAY_SECONDS || 20)

/**
 * @param {object} ctx - cordis plugin context (unused).
 */
export function apply(ctx) {
  try {
    appendFileSync(TRIGGER_LOG, `[${new Date().toISOString()}] apply() called\n`)
  } catch {
    // logging must never break DSH startup
  }

  try {
    // Single-quoted PowerShell string: escape embedded single quotes.
    const psPath = CHECK_SCRIPT.replace(/'/g, "''")
    const command = `Start-Sleep -Seconds ${DELAY_SECONDS}; if (Test-Path '${psPath}') { & '${psPath}' }`

    const child = spawn(
      'powershell.exe',
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-Command',
        command,
      ],
      {
        detached: true,
        stdio: 'ignore',
        windowsHide: true,
      },
    )

    child.on('error', () => {})
    child.unref()
  } catch {
    // never break DSH startup
  }
}
