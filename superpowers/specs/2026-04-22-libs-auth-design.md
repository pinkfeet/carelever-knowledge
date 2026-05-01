# `libs/auth` Build — Design Spec

Date: 2026-04-22

Companion to [authz-design.md](../../auth/authz-design.md), narrowing Phase 5 + the first slice of Phase 6 (internal portal) into a single PR-shaped scope.

## Goal

Build the shared Angular `libs/auth` library in `carelever_assessment_ui` and wire `apps/internal` as its first consumer end-to-end against the dev auth service at `https://authentication-api.dev.carelever.com`.

## Scope

In:

- New `libs/auth` surface: services, interceptors, guards, claims model, OTP component, config tokens.
- Move `authInterceptor` + `AUTH_TOKEN_KEY` from `libs/api` to `libs/auth`.
- Remove `LoginComponent` and `MasqueradeComponent` from `libs/auth`.
- New `InternalLoginComponent` in `apps/internal/src/app/login/`.
- Wire `apps/internal/app.config.ts` and `app.routes.ts` to the new lib.
- Vitest unit tests for everything in the lib.
- Manual end-to-end QA against the dev backend.

Out (separate PRs):

- `apps/client`, `apps/affiliate`, `apps/doctor` wiring.
- `GET /v1/me` consumer (backend endpoint is Phase 1 of the parent spec).
- Forgot/reset password flows.
- Token refresh.
- Removing the legacy `Authentication:` header fallback (Phase 7 cleanup).

## Backend Contract (verified against carelever_internal_ui and carelever_client_ui)

Two hosts in dev — the lib must talk to both.

| Token | Dev URL | Used for |
|---|---|---|
| `AUTH_SERVICE_BASE_URL` | `https://authentication-api.dev.carelever.com` | `POST /<classification>/authenticate` |
| `AUTH_LEGACY_BASE_URL` | `https://api.dev.carelever.com` | `POST /authentication/<classification>/{request_otp,authenticate_otp}` |

`<classification>` ∈ `internal | external | affiliate`. Affiliate has no OTP endpoints.

### `POST /<classification>/authenticate` (new host)

Request:

```http
POST https://authentication-api.dev.carelever.com/internal/authenticate
Content-Type: application/json
withCredentials: true

{ "login": "jc@kinnect", "password": "..." }
```

Response (200):

```json
{ "data": { "loginAttempt": "success" | "otp_required", "token": "<jwt>" } }
```

- `loginAttempt = "success"` → `token` is the final JWT. Store in `AUTH_TOKEN_KEY`.
- `loginAttempt = "otp_required"` → `token` is the pre-OTP JWT (carries `user_id`). Store in `OTP_CONFIRMATION_TOKEN_KEY`.

`login` field shape per classification:

| Classification | Login field | Source |
|---|---|---|
| `internal` | `username@org-slug` (e.g. `jc@kinnect`) | knowledge base |
| `external` | email address | knowledge base |
| `affiliate` | `username@org-slug` | knowledge base |

### `POST /authentication/<classification>/request_otp` (legacy host)

```http
POST https://api.dev.carelever.com/authentication/internal/request_otp
Content-Type: application/json
Authentication: <pre-otp-jwt>          ← custom header, NOT Authorization: Bearer
withCredentials: true

{ "user_id": "<uuid from pre-otp jwt>" }
```

Response shape: `{ data: ... }` (we don't consume the body — fire-and-forget).

### `POST /authentication/<classification>/authenticate_otp` (legacy host)

```http
POST https://api.dev.carelever.com/authentication/internal/authenticate_otp
Content-Type: application/json
Authentication: <pre-otp-jwt>
withCredentials: true

{ "user_id": "<uuid from pre-otp jwt>", "otp": "123456" }
```

Response (200):

```json
{ "data": "<final-jwt>" }
```

Token sits **directly in `data`** — different from the initial authenticate response. Store in `AUTH_TOKEN_KEY`, clear `OTP_CONFIRMATION_TOKEN_KEY`.

## File Layout

```
libs/auth/src/
  index.ts                                 # public exports
  lib/
    auth.config.ts                         # InjectionTokens + storage key constants
    claims.model.ts                        # JwtClaims interface, Classification union, LoginResult union
    auth.service.ts                        # token state signals, login(), logout()
    otp.service.ts                         # requestOtp(), authenticateOtp() — decodes user_id from pre-OTP token
    me.service.ts                          # GET /v1/me stub (consumer comes in a later PR)
    token.interceptor.ts                   # functional HttpInterceptorFn — Bearer for API_BASE_URL only
    error.interceptor.ts                   # 401 on API_BASE_URL → logout + redirect
    auth.guard.ts                          # authGuard — requires logged in
    classification.guard.ts                # classificationGuard(['internal'|'external'|'affiliate'])
    components/
      otp/
        otp.component.ts                   # 6-digit input, submit, resend
        otp.component.html

apps/internal/src/
  environments/
    environment.ts                         # add authServiceUrl, authLegacyUrl
    environment.dev.ts                     # same, dev URLs
    environment.staging.ts                 # same, staging URLs
    environment.prod.ts                    # same, prod URLs
  app/
    app.config.ts                          # provide both URL tokens, register tokenInterceptor + errorInterceptor (drop @org/api authInterceptor)
    app.routes.ts                          # /login → InternalLoginComponent; /login/otp → OtpComponent; root canActivate
    login/
      login.component.ts                   # form { login, password }; routes per LoginResult
      login.component.html
```

Removed: `libs/auth/src/lib/login/`, `libs/auth/src/lib/masquerade/`, the broken `atob` role decoder in the existing `auth.service.ts`. `libs/api/src/lib/auth.interceptor.ts` and `AUTH_TOKEN_KEY` constant deleted; `libs/api` keeps `API_BASE_URL`.

## Public Surface — `libs/auth/src/index.ts`

```ts
export {
  AUTH_SERVICE_BASE_URL,
  AUTH_LEGACY_BASE_URL,
  AUTH_TOKEN_KEY,
  OTP_CONFIRMATION_TOKEN_KEY,
} from './lib/auth.config';
export type { Classification, JwtClaims, LoginResult } from './lib/claims.model';
export { AuthService } from './lib/auth.service';
export { OtpService } from './lib/otp.service';
export { MeService } from './lib/me.service';
export { tokenInterceptor } from './lib/token.interceptor';
export { errorInterceptor } from './lib/error.interceptor';
export { authGuard } from './lib/auth.guard';
export { classificationGuard } from './lib/classification.guard';
export { OtpComponent } from './lib/components/otp/otp.component';
```

## `claims.model.ts`

```ts
export type Classification = 'internal' | 'external' | 'affiliate';

export interface JwtClaims {
  user_id: string;
  classification: Classification;
  is_internal: boolean;
  email: string;
  first_name: string;
  last_name: string;
  organisation_id?: string;
  organisation_slug?: string;
  exp: number;
}

export type LoginResult =
  | { status: 'success' }
  | { status: 'otp_required' };
```

## `auth.config.ts`

```ts
export const AUTH_SERVICE_BASE_URL  = new InjectionToken<string>('AUTH_SERVICE_BASE_URL');
export const AUTH_LEGACY_BASE_URL   = new InjectionToken<string>('AUTH_LEGACY_BASE_URL');
export const AUTH_TOKEN_KEY              = 'auth_token';
export const OTP_CONFIRMATION_TOKEN_KEY  = 'otp_confirmation_token';
```

Storage key string `'otp_confirmation_token'` matches legacy code so a user mid-OTP-flow during deployment isn't logged out.

## `AuthService`

```ts
@Injectable({ providedIn: 'root' })
export class AuthService {
  readonly token: Signal<string | null>;
  readonly claims: Signal<JwtClaims | null>;
  readonly classification: Signal<Classification | null>;
  readonly isInternal: Signal<boolean>;
  readonly isLoggedIn: Signal<boolean>;          // token present AND not expired

  login(classification: Classification, login: string, password: string): Observable<LoginResult>;
  logout(): void;
}
```

Behavior notes:

- Constructor seeds `token` from `localStorage.getItem(AUTH_TOKEN_KEY)`.
- `claims` decodes the JWT payload using `@auth0/angular-jwt`'s `JwtHelperService` (`decodeToken`). Same lib legacy internal-ui already uses; handles base64url encoding correctly. Returns `null` on malformed input via try/catch.
- `isLoggedIn` uses `JwtHelperService.isTokenExpired` for the expiry check.

### Dependency

Add `@auth0/angular-jwt` to `carelever_assessment_ui/package.json` (`pnpm add @auth0/angular-jwt`). `JwtHelperService` is `providedIn: 'root'` from the lib — no extra DI wiring required.
- `isLoggedIn` checks both presence AND `claims.exp > now`.
- `login()` POSTs to `${AUTH_SERVICE_BASE_URL}/<classification>/authenticate` with `{ login, password }` and `withCredentials: true`. Maps the response: `'success'` → write `AUTH_TOKEN_KEY`; `'otp_required'` → write `OTP_CONFIRMATION_TOKEN_KEY`.
- `logout()` removes both keys and resets the token signal. No server call.

## `OtpService`

```ts
@Injectable({ providedIn: 'root' })
export class OtpService {
  requestOtp(classification: Classification): Observable<void>;
  authenticateOtp(classification: Classification, code: string): Observable<void>;
}
```

Behavior:

- Both methods read `OTP_CONFIRMATION_TOKEN_KEY` from localStorage to extract `user_id` (decode JWT payload).
- Both POST to `${AUTH_LEGACY_BASE_URL}/authentication/<classification>/{request_otp,authenticate_otp}`.
- Both set the custom `Authentication: <pre-otp-token>` header. The token interceptor will skip these requests (URL-prefix match on `AUTH_LEGACY_BASE_URL`) so it doesn't also append `Authorization: Bearer`.
- Both use `withCredentials: true`.
- `authenticateOtp` reads the response body's `data` as the final JWT string, writes to `AUTH_TOKEN_KEY`, removes `OTP_CONFIRMATION_TOKEN_KEY`, updates the `AuthService.token` signal.
- Throws if `OTP_CONFIRMATION_TOKEN_KEY` is missing — caller misuse.

## Interceptors

```ts
// token.interceptor.ts
export const tokenInterceptor: HttpInterceptorFn = (req, next) => {
  const authBaseUrl   = inject(AUTH_SERVICE_BASE_URL);
  const legacyAuthUrl = inject(AUTH_LEGACY_BASE_URL);
  if (req.url.startsWith(authBaseUrl) || req.url.startsWith(legacyAuthUrl)) {
    return next(req);
  }
  const token = localStorage.getItem(AUTH_TOKEN_KEY);
  return token
    ? next(req.clone({ setHeaders: { Authorization: `Bearer ${token}` } }))
    : next(req);
};

// error.interceptor.ts
export const errorInterceptor: HttpInterceptorFn = (req, next) => {
  const auth       = inject(AuthService);
  const router     = inject(Router);
  const apiBaseUrl = inject(API_BASE_URL);
  return next(req).pipe(catchError(err => {
    if (err.status === 401 && req.url.startsWith(apiBaseUrl)) {
      auth.logout();
      router.navigate(['/login']);
    }
    return throwError(() => err);
  }));
};
```

URL-prefix-based skipping replaces the legacy `INTERCEPTOR_TOKEN_SKIP_HEADER` mechanism. Cleaner: no per-request opt-out header to maintain.

Auth-service 401s (bad password, bad OTP) propagate to the calling component for inline error display — they are not redirected.

## Guards

```ts
export const authGuard: CanActivateFn = () =>
  inject(AuthService).isLoggedIn() || inject(Router).createUrlTree(['/login']);

export const classificationGuard = (allowed: Classification[]): CanActivateFn => () => {
  const c = inject(AuthService).classification();
  return c !== null && allowed.includes(c) || inject(Router).createUrlTree(['/login']);
};
```

## `OtpComponent`

Single shared component reused by internal, client, doctor apps in later PRs. Lives at `libs/auth/src/lib/components/otp/`.

- Reactive form: 6-digit code input.
- Inputs: none — reads classification from current route data (apps wire `data: { classification: 'internal' }` on the route).
- On submit → `OtpService.authenticateOtp(classification, code)`. On success, navigates to route `data.successRedirect` (default `/dashboard`).
- "Resend code" button → `OtpService.requestOtp(classification)`. Cooldown timer (30s) before re-enable.
- Inline error message on backend failure.

Affiliate apps don't route to this component.

## `InternalLoginComponent`

Lives at `apps/internal/src/app/login/login.component.ts`.

- Reactive form: `{ login: required, password: required }`.
- On submit → `authService.login('internal', login, password)`.
- On `LoginResult.status === 'success'` → `router.navigate(['/dashboard'])`.
- On `LoginResult.status === 'otp_required'` → `router.navigate(['/login/otp'])`.
- On error → inline error message ("Invalid credentials" or backend error message).

Bare-bones styling for this PR — the goal is a working login, not a finished UX. Visual polish lands in a follow-up.

## `apps/internal` Wiring Changes

### `environments/environment.ts` (and dev/staging/prod variants)

```ts
export const environment = {
  production: false,
  apiUrl:         'http://localhost:3000/v1',
  authServiceUrl: 'https://authentication-api.dev.carelever.com',
  authLegacyUrl:  'https://api.dev.carelever.com',
};
```

Same shape across all env files; URLs differ per env.

### `app.config.ts`

```ts
export const appConfig: ApplicationConfig = {
  providers: [
    provideBrowserGlobalErrorListeners(),
    provideZonelessChangeDetection(),
    provideRouter(appRoutes, withComponentInputBinding()),
    provideHttpClient(withInterceptors([tokenInterceptor, errorInterceptor])),
    { provide: API_BASE_URL,             useValue: environment.apiUrl },
    { provide: AUTH_SERVICE_BASE_URL,    useValue: environment.authServiceUrl },
    { provide: AUTH_LEGACY_BASE_URL,     useValue: environment.authLegacyUrl },
  ],
};
```

Drops `authInterceptor` import from `@org/api`. Adds two new URL token providers.

### `app.routes.ts`

```ts
export const appRoutes: Route[] = [
  { path: 'login',     component: InternalLoginComponent },
  { path: 'login/otp', component: OtpComponent, data: { classification: 'internal', successRedirect: '/dashboard' } },
  {
    path: '',
    component: ShellComponent,
    canActivate: [authGuard, classificationGuard(['internal'])],
    children: [ /* unchanged */ ],
  },
  { path: '**', redirectTo: '' },
];
```

Adds `classificationGuard(['internal'])` at root. `InternalLoginComponent` replaces the imported `LoginComponent` from `@org/auth`.

## Tests (Vitest)

`libs/auth/src/lib/`:

| File | Coverage |
|---|---|
| `auth.service.spec.ts` | login success branch, login otp_required branch, logout clears both keys, claims signal decodes a valid JWT, claims returns null on malformed token, isLoggedIn handles expired exp |
| `otp.service.spec.ts` | requestOtp posts to correct URL with custom header + user_id from pre-otp token; authenticateOtp swaps tokens; throws when pre-otp token missing |
| `token.interceptor.spec.ts` | attaches Bearer to API_BASE_URL request; skips AUTH_SERVICE_BASE_URL request; skips AUTH_LEGACY_BASE_URL request; passes through when no token present |
| `error.interceptor.spec.ts` | redirects + logs out on 401 to API_BASE_URL; does NOT redirect on 401 to auth-service URLs; passes through non-401 errors |
| `auth.guard.spec.ts` | returns true when logged in; returns UrlTree to /login when not |
| `classification.guard.spec.ts` | allows match; blocks mismatch; blocks null |
| `components/otp/otp.component.spec.ts` | submit calls authenticateOtp with code; navigates on success; shows error on failure; resend disables for cooldown |

`apps/internal/src/app/login/login.component.spec.ts`: form submit happy path → navigate to `/dashboard`; otp_required → navigate to `/login/otp`; error → inline message.

End-to-end manual QA against the dev backend documented in the implementation plan, not automated.

## Migration / Coexistence Notes

- `libs/api/src/index.ts` stops exporting `authInterceptor` and `AUTH_TOKEN_KEY`. Confirmed no other consumers in `carelever_assessment_ui` (only `apps/internal/app.config.ts`, which we update in this PR).
- Existing `libs/auth/src/lib/auth.service.ts` is rewritten in place; `Role` type and `MasqueradeComponent` deleted.
- Storage key `'auth_token'` (`AUTH_TOKEN_KEY`) is preserved verbatim for continuity. `'otp_confirmation_token'` matches legacy too.

## Open Questions Resolved During Brainstorm

- Per-app login components (not a shared parameterized one). ✓
- Shared `OtpComponent` in libs/auth. ✓
- Lib + wire `apps/internal` in same PR. ✓
- Two URL InjectionTokens (auth host + legacy host). ✓
- URL-prefix-based interceptor skipping (no custom skip header). ✓

## Risks

| Risk | Mitigation |
|---|---|
| Backend `/v1/me` not yet built when later apps need it | Out of scope here; `MeService` shipped as a stub but unused |
| Custom `Authentication:` header dropped by some proxy | Verified in legacy production, no change in transport |
| User mid-OTP flow during deploy | Storage key names match legacy verbatim — pre-OTP token survives the swap |
| CORS misconfig on dev auth host | Manual smoke test against `authentication-api.dev.carelever.com` before merge |

## Acceptance

- `nx test auth` green.
- `nx test internal` green.
- `nx build internal` green.
- Manual: from `apps/internal`, log in as a real internal user against dev → OTP step → land on `/dashboard` with valid JWT in localStorage; reload and stay logged in; logout clears both keys.
