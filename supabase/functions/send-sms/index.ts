// Supabase Edge Function: Send SMS hook → Semaphore.
//
// Auth owns the OTP; this endpoint only delivers it. Requests must be signed
// with the Standard Webhooks secret configured in Auth → Hooks → Send SMS.
import { handleSendSms } from './handler.ts';

Deno.serve((request) =>
  handleSendSms(request, {
    hookSecret: Deno.env.get('SEND_SMS_HOOK_SECRET') ?? '',
    semaphoreApiKey: Deno.env.get('SEMAPHORE_API_KEY') ?? '',
    semaphoreSenderName: Deno.env.get('SEMAPHORE_SENDER_NAME') || undefined,
  })
);
