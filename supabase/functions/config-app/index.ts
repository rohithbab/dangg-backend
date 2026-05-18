/**
 * GET /functions/v1/config-app
 *
 * Returns app-level configuration the mobile app reads on every launch and
 * resume: version gates, maintenance mode, cost defaults, support contacts,
 * legal URLs.
 *
 * Public endpoint — no JWT required (config governs the gate that PROMPTS
 * for auth, so requiring auth here would be circular).
 *
 * Source: hardcoded today. Later this reads from an `app_config` row
 * managed via the admin dashboard; the CONTRACT is what matters now.
 */
import { handlePreflight } from '../_shared/cors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';

interface AppConfig {
  minSupportedVersion: string;
  latestVersion: string;
  forceUpdate: boolean;
  maintenanceMode: boolean;
  defaultChatCost: number;
  payoutMinAmount: number;
  payoutMaxPending: number;
  supportEmail: string;
  supportPhone: string;
  termsUrl: string;
  privacyUrl: string;
}

const config: AppConfig = {
  minSupportedVersion: '1.0.0',
  latestVersion: '1.0.0',
  forceUpdate: false,
  maintenanceMode: false,
  defaultChatCost: 50,
  payoutMinAmount: 500,
  payoutMaxPending: 1,
  supportEmail: 'support@dangg.app',
  supportPhone: '+918012345678',
  termsUrl: 'https://dangg.app/terms',
  privacyUrl: 'https://dangg.app/privacy',
};

Deno.serve(
  handler((req: Request): Response => {
    const preflight = handlePreflight(req);
    if (preflight) {
      return preflight;
    }

    logger.info('config-app called', { method: req.method });

    return ok(config);
  }),
);
