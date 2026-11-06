import type { NextRequest } from 'next/server';
import { updateSession } from '@/lib/supabase/middleware';
export const middleware = (req: NextRequest) => updateSession(req);
export const config = { matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'] };
