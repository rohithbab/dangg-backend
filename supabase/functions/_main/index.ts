/**
 * Edge Runtime gateway — routes /functions/v1/{name} requests to the
 * corresponding worker at supabase/functions/{name}/index.ts.
 *
 * This file is the --main-service entry point for the supabase/edge-runtime
 * Docker container. It is NOT a Supabase Edge Function itself.
 */
const FUNCTIONS_PATH = Deno.env.get('FUNCTIONS_PATH') ?? '/usr/services/functions';

const ENV_KEYS = [
  'SUPABASE_URL',
  'SUPABASE_ANON_KEY',
  'SUPABASE_SERVICE_ROLE_KEY',
  'CLOUDINARY_CLOUD_NAME',
  'CLOUDINARY_API_KEY',
  'CLOUDINARY_API_SECRET',
  'RAZORPAY_KEY_ID',
  'RAZORPAY_KEY_SECRET',
  'RAZORPAY_WEBHOOK_SECRET',
  'SEND_SMS_HOOK_SECRET',
  'MSG91_AUTH_KEY',
  'MSG91_SENDER_ID',
  'MSG91_OTP_TEMPLATE_ID',
  'R2_ACCOUNT_ID',
  'R2_ACCESS_KEY_ID',
  'R2_SECRET_ACCESS_KEY',
  'R2_BUCKET_NAME',
  'R2_S3_ENDPOINT',
  'R2_PUBLIC_BASE_URL',
  'APP_ENV',
];

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  const path = url.pathname;

  if (path === '/health' || path === '/') {
    return new Response(JSON.stringify({ status: 'ok', service: 'dangg-backend' }), {
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // Accept /functions/v1/{name}/... or /{name}/...
  const match = path.match(/^(?:\/functions\/v1)?\/([^\/]+)(\/.*)?$/);
  if (!match || match[1] === 'health') {
    return new Response(JSON.stringify({ error: 'not_found' }), {
      status: 404,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const functionName = match[1];
  const servicePath = `${FUNCTIONS_PATH}/${functionName}/index.ts`;
  const importMapPath = `${FUNCTIONS_PATH}/${functionName}/deno.json`;

  const envVars: Record<string, string> = {};
  for (const key of ENV_KEYS) {
    const val = Deno.env.get(key);
    if (val) envVars[key] = val;
  }

  try {
    // @ts-ignore — EdgeRuntime is injected as a global by the edge-runtime host
    const worker = await EdgeRuntime.userWorkers.create({
      servicePath,
      memoryLimitMb: 150,
      workerTimeoutMs: 10_000,
      envVars,
      noModuleCache: false,
      importMapPath,
      forceCreate: false,
      netAccessDisabled: false,
      customModuleRoot: '',
    });
    return await worker.fetch(req);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error(`[${functionName}] error: ${msg}`);
    const notFound = msg.toLowerCase().includes('not found') ||
      msg.includes('ENOENT') ||
      msg.includes('No such file');
    return new Response(
      JSON.stringify({ error: notFound ? 'function_not_found' : 'internal_server_error' }),
      {
        status: notFound ? 404 : 500,
        headers: { 'Content-Type': 'application/json' },
      },
    );
  }
});
