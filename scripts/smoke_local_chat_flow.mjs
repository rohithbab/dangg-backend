#!/usr/bin/env node

const API_URL = process.env.SUPABASE_API_URL ?? 'http://127.0.0.1:54321';
const anonKey =
  process.env.SUPABASE_ANON_KEY ??
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';
const password = 'Password123!';

async function request(url, options) {
  const res = await fetch(url, options);
  const text = await res.text();
  const body = text ? JSON.parse(text) : null;

  if (!res.ok) {
    const message = body?.msg ?? body?.message ?? text;
    throw new Error(`${options.method ?? 'GET'} ${url} failed: ${res.status} ${message}`);
  }

  return body;
}

function authHeaders(token = anonKey) {
  return {
    apikey: anonKey,
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json',
  };
}

async function signIn(phone) {
  const body = await request(`${API_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify({ phone, password }),
  });

  return body.access_token;
}

async function rpc(name, token, args) {
  return await request(`${API_URL}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: authHeaders(token),
    body: JSON.stringify(args ?? {}),
  });
}

async function getPhoneForUserId(userId) {
  const rows = await request(`${API_URL}/rest/v1/users?id=eq.${userId}&select=phone`, {
    method: 'GET',
    headers: authHeaders(process.env.SUPABASE_SERVICE_ROLE_KEY ??
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU'),
  });

  return rows[0]?.phone ? `+${rows[0].phone}` : null;
}

async function invoke(name, token, payload) {
  const envelope = await request(`${API_URL}/functions/v1/${name}`, {
    method: 'POST',
    headers: authHeaders(token),
    body: JSON.stringify(payload),
  });

  if (envelope?.ok === true) {
    return envelope.data;
  }

  return envelope;
}

async function insertMessage(token, sessionId, body) {
  const rows = await request(`${API_URL}/rest/v1/chat_messages`, {
    method: 'POST',
    headers: {
      ...authHeaders(token),
      Prefer: 'return=representation',
    },
    body: JSON.stringify({
      chat_session_id: sessionId,
      body,
      sender_id: await getUserId(token),
    }),
  });

  return rows[0];
}

async function getUserId(token) {
  const user = await request(`${API_URL}/auth/v1/user`, {
    method: 'GET',
    headers: authHeaders(token),
  });
  return user.id;
}

async function main() {
  const maleToken = await signIn('+919900000001');

  const browse = await rpc('browse_females', maleToken, {
    p_filters: { quick: 'online', onlineOnly: true },
    p_offset: 0,
    p_limit: 10,
  });

  if (!browse.items?.length) {
    throw new Error('browse_females returned no online females');
  }

  const female = browse.items[0];
  const femalePhone = await getPhoneForUserId(female.id);
  if (!femalePhone) {
    throw new Error(`Could not resolve phone for female ${female.id}`);
  }
  const femaleToken = await signIn(femalePhone);

  const sent = await invoke('chat-requests-send', maleToken, {
    femaleId: female.id,
  });

  const accepted = await invoke('chat-requests-respond', femaleToken, {
    chatRequestId: sent.chatRequestId,
    action: 'accept',
  });

  if (!accepted.chatSessionId) {
    throw new Error('accept did not return chatSessionId');
  }

  const maleMessage = await insertMessage(
    maleToken,
    accepted.chatSessionId,
    'Hi, this is a seeded smoke-test message from the male.',
  );
  const femaleMessage = await insertMessage(
    femaleToken,
    accepted.chatSessionId,
    'Hello, this is a seeded smoke-test reply from the female.',
  );

  console.log('Smoke flow passed');
  console.table({
    browsedFemale: female.name,
    chatRequestId: sent.chatRequestId,
    chatSessionId: accepted.chatSessionId,
    maleMessageId: maleMessage.id,
    femaleMessageId: femaleMessage.id,
  });
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
