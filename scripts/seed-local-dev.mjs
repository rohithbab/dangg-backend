#!/usr/bin/env node

const API_URL = process.env.SUPABASE_API_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY =
  process.env.SUPABASE_SERVICE_ROLE_KEY ??
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU';

const PASSWORD = 'Password123!';

const females = [
  {
    phone: '+919900000101',
    name: 'Aanya',
    age: 22,
    coinPrice: 80,
    ratingAvg: 4.9,
    totalChats: 120,
    averageResponseMinutes: 2,
    bio: 'Warm, funny, and always up for a real conversation.',
    imageUrl:
      'https://images.unsplash.com/photo-1534528741775-53994a69daeb?w=300&auto=format&fit=crop&q=80',
  },
  {
    phone: '+919900000102',
    name: 'Priya',
    age: 24,
    coinPrice: 50,
    ratingAvg: 4.8,
    totalChats: 95,
    averageResponseMinutes: 4,
    bio: 'Music, movies, and relaxed late-night conversations.',
    imageUrl:
      'https://images.unsplash.com/photo-1517841905240-472988babdf9?w=300&auto=format&fit=crop&q=80',
  },
  {
    phone: '+919900000103',
    name: 'Riya',
    age: 21,
    coinPrice: 120,
    ratingAvg: 4.7,
    totalChats: 140,
    averageResponseMinutes: 1,
    bio: 'Quick replies, light humor, and easy conversation.',
    imageUrl:
      'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=300&auto=format&fit=crop&q=80',
  },
];

const males = [
  {
    phone: '+919900000001',
    name: 'Arjun',
    age: 27,
    coinBalance: 2000,
  },
  {
    phone: '+919900000002',
    name: 'Vikram',
    age: 30,
    coinBalance: 1000,
  },
];

function headers(extra = {}) {
  return {
    apikey: SERVICE_ROLE_KEY,
    Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
    'Content-Type': 'application/json',
    ...extra,
  };
}

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

async function createAuthUser(user, role) {
  return await request(`${API_URL}/auth/v1/admin/users`, {
    method: 'POST',
    headers: headers(),
    body: JSON.stringify({
      phone: user.phone,
      password: PASSWORD,
      phone_confirm: true,
      user_metadata: {
        role,
        name: user.name,
        age: user.age,
      },
      app_metadata: {
        role,
      },
    }),
  });
}

async function patchTable(table, id, payload) {
  await request(`${API_URL}/rest/v1/${table}?id=eq.${id}`, {
    method: 'PATCH',
    headers: headers({ Prefer: 'return=minimal' }),
    body: JSON.stringify(payload),
  });
}

async function upsertPayoutDetails(femaleId) {
  await request(`${API_URL}/rest/v1/payout_details`, {
    method: 'POST',
    headers: headers({
      Prefer: 'resolution=merge-duplicates,return=minimal',
    }),
    body: JSON.stringify({
      female_id: femaleId,
      method: 'upi',
      upi_id: `seed.${femaleId.slice(0, 8)}@upi`,
    }),
  });
}

async function seed() {
  console.log(`Seeding local Supabase at ${API_URL}`);

  const createdFemales = [];
  for (const female of females) {
    const authUser = await createAuthUser(female, 'female');
    createdFemales.push({ ...female, id: authUser.id });

    await patchTable('users', authUser.id, {
      profile_picture_url: female.imageUrl,
    });
    await patchTable('females', authUser.id, {
      verification_status: 'verified',
      verification_submitted_at: new Date().toISOString(),
      verification_decided_at: new Date().toISOString(),
      is_online: true,
      last_online_at: new Date().toISOString(),
      bio: female.bio,
      rating_avg: female.ratingAvg,
      total_chats: female.totalChats,
      total_ratings: Math.max(female.totalChats, 1),
      coin_price: female.coinPrice,
      average_response_minutes: female.averageResponseMinutes,
    });
    await upsertPayoutDetails(authUser.id);
  }

  const createdMales = [];
  for (const male of males) {
    const authUser = await createAuthUser(male, 'male');
    createdMales.push({ ...male, id: authUser.id });
    await patchTable('males', authUser.id, {
      coin_balance: male.coinBalance,
      total_coins_purchased: male.coinBalance,
    });
  }

  console.log('\nSeeded users');
  console.table([
    ...createdMales.map(user => ({
      role: 'male',
      phone: user.phone,
      password: PASSWORD,
      id: user.id,
    })),
    ...createdFemales.map(user => ({
      role: 'female',
      phone: user.phone,
      password: PASSWORD,
      id: user.id,
    })),
  ]);
}

seed().catch(error => {
  console.error(error);
  process.exit(1);
});
