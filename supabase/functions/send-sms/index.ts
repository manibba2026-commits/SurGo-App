// Supabase Edge Function: Send SMS hook → configured SMS provider.
//
// Auth owns the OTP; this endpoint only delivers it. Requests must be signed
// with the Standard Webhooks secret configured in Auth → Hooks → Send SMS.
import { handleSendSms } from './handler.ts';

Deno.serve((request) =>
  handleSendSms(request, {
    hookSecret: Deno.env.get('SEND_SMS_HOOK_SECRET') ?? '',
    smsProvider: Deno.env.get('SMS_PROVIDER'),
    semaphoreApiKey: Deno.env.get('SEMAPHORE_API_KEY') ?? '',
    semaphoreSenderName: Deno.env.get('SEMAPHORE_SENDER_NAME') || undefined,
    unisms: {
      apiKey: Deno.env.get('UNISMS_API_KEY') ?? '',
      senderId: Deno.env.get('UNISMS_SENDER_ID') || undefined,
    },
    // UniSMS settles asynchronously; read the status before reporting success.
    // Set UNISMS_VERIFY_DELIVERY=false only if the provider's status endpoint
    // is unavailable.
    verifyDelivery: Deno.env.get('UNISMS_VERIFY_DELIVERY') !== 'false',
  })
);
