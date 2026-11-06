/** The single SMS body SurGo sends for a Supabase-generated OTP. */
export function buildOtpMessage(otp: string): string {
  return `Your SurGo verification code is: ${otp}. Do not share this code with anyone.`;
}
