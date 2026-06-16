/**
 * POST /functions/v1/push-dispatch
 *
 * Internal webhook triggered by public.notifications insert.
 * Dispatches FCM push notifications to registered devices of the recipient.
 */
import { handlePreflight } from '../_shared/cors.ts';
import { logger } from '../_shared/logger.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { sendPushToUser } from '../_shared/fcm.ts';

Deno.serve(async (req: Request): Promise<Response> => {
  const preflight = handlePreflight(req);
  if (preflight) {
    return preflight;
  }

  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method Not Allowed' }), {
      status: 405,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  try {
    const payload = await req.json();
    logger.info('push-dispatch: received webhook payload', {
      type: payload.type,
      table: payload.table,
    });

    if (payload.type === 'INSERT' && payload.table === 'notifications') {
      const record = payload.record;
      if (!record) {
        logger.warn('push-dispatch: no record found in payload');
        return new Response(JSON.stringify({ success: false, error: 'No record in payload' }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      const recipientId = record.recipient_id;
      const type = record.type;
      const title = record.title;
      const body = record.body;
      const data = record.data ?? {};

      if (!recipientId || !title || !body) {
        logger.warn('push-dispatch: missing required fields', { recipientId, title, body });
        return new Response(
          JSON.stringify({ success: false, error: 'Missing recipient_id, title, or body' }),
          {
            status: 400,
            headers: { 'Content-Type': 'application/json' },
          },
        );
      }

      logger.info('push-dispatch: sending push', { recipientId, type });
      const svc = serviceClient();

      const count = await sendPushToUser(svc, recipientId, {
        title,
        body,
        data: { ...data, type },
      });

      logger.info('push-dispatch: push delivery completed', {
        recipientId,
        type,
        delivered: count,
      });
      return new Response(JSON.stringify({ success: true, delivered: count }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    return new Response(
      JSON.stringify({ success: true, message: 'Ignored non-notification insert event' }),
      {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      },
    );
  } catch (err) {
    logger.error('push-dispatch: unexpected error', {
      error: err instanceof Error ? err.message : String(err),
    });
    return new Response(JSON.stringify({ success: false, error: String(err) }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    });
  }
});
