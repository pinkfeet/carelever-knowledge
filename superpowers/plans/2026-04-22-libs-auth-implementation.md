# `libs/auth` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the shared Angular `libs/auth` library in `carelever_assessment_ui` and wire `apps/internal` end-to-end against the dev auth service at `https://authentication-api.dev.carelever.com`.

**Architecture:** Shared library exporting an `AuthService` (token state via signals), `OtpService`, two functional `HttpInterceptorFn`s, two `CanActivateFn` guards, a shared `OtpComponent`, and a JWT claims model. Per-app `LoginComponent` lives in each portal's app folder. Two URL injection tokens reflect the backend's split between the new auth host (`/internal/authenticate`) and the legacy host (`/authentication/internal/authenticate_otp`).

**Tech Stack:** Angular 21.2, Vitest, `@auth0/angular-jwt`, Nx 22.6, RxJS 7.8, `@analogjs/vite-plugin-angular`. Tests use `HttpTestingController` + `provideHttpClientTesting`.

**Companion docs:**

- Spec: [`docs/superpowers/specs/2026-04-22-libs-auth-design.md`](../specs/2026-04-22-libs-auth-design.md)
- Parent design: [`docs/auth/AUTHZ_AND_AUDIT_CURRENT.md`](../../auth/AUTHZ_AND_AUDIT_CURRENT.md)

**Working directory for code:** `/Users/jcshin/dev/cl/carelever_assessment_ui` (not this repo). All paths below are relative to that workspace.

---

## File Map

**New files (libs/auth):**

- `libs/auth/src/lib/auth.config.ts` — InjectionTokens + storage key constants
- `libs/auth/src/lib/claims.model.ts` — `JwtClaims`, `Classification`, `LoginResult` types
- `libs/auth/src/lib/auth.service.ts` — token state signals, `login()`, `logout()`
- `libs/auth/src/lib/auth.service.spec.ts`
- `libs/auth/src/lib/otp.service.ts` — `requestOtp()`, `authenticateOtp()`
- `libs/auth/src/lib/otp.service.spec.ts`
- `libs/auth/src/lib/me.service.ts` — `GET /v1/me` stub
- `libs/auth/src/lib/token.interceptor.ts`
- `libs/auth/src/lib/token.interceptor.spec.ts`
- `libs/auth/src/lib/error.interceptor.ts`
- `libs/auth/src/lib/error.interceptor.spec.ts`
- `libs/auth/src/lib/auth.guard.spec.ts` (new spec; existing `auth.guard.ts` is rewritten in place)
- `libs/auth/src/lib/classification.guard.ts`
- `libs/auth/src/lib/classification.guard.spec.ts`
- `libs/auth/src/lib/components/otp/otp.component.ts`
- `libs/auth/src/lib/components/otp/otp.component.html`
- `libs/auth/src/lib/components/otp/otp.component.spec.ts`

**Modified files (libs/auth):**

- `libs/auth/src/lib/auth.guard.ts` — rewritten (move out of nested directory if applicable, keep functional guard signature)
- `libs/auth/src/index.ts` — public exports
- `libs/auth/project.json` — add `test` target

**Deleted files (libs/auth):**

- `libs/auth/src/lib/auth/` (whole directory: `auth.service.ts`, `auth.css`, `auth.html`)
- `libs/auth/src/lib/login/` (whole directory: `login.component.ts`, `login.component.html`)
- `libs/auth/src/lib/masquerade/` (whole directory)

**Modified files (libs/api):**

- `libs/api/src/lib/auth.interceptor.ts` — deleted
- `libs/api/src/lib/api.config.ts` — drop `AUTH_TOKEN_KEY` constant
- `libs/api/src/index.ts` — remove `authInterceptor` and `AUTH_TOKEN_KEY` exports

**New files (apps/internal):**

- `apps/internal/src/app/login/login.component.ts`
- `apps/internal/src/app/login/login.component.html`
- `apps/internal/src/app/login/login.component.spec.ts`

**Modified files (apps/internal):**

- `apps/internal/src/environments/environment.ts` — add `authServiceUrl`, `authLegacyUrl`
- `apps/internal/src/environments/environment.dev.ts` — same
- `apps/internal/src/environments/environment.staging.ts` — same
- `apps/internal/src/environments/environment.prod.ts` — same
- `apps/internal/src/app/app.config.ts` — provide URL tokens, swap interceptors
- `apps/internal/src/app/app.routes.ts` — add OTP route, add `classificationGuard(['internal'])`

**Modified files (workspace root):**

- `package.json` — add `@auth0/angular-jwt`

---

## Task 0: Pre-flight — dependency + test target

**Files:**

- Modify: `package.json`
- Modify: `libs/auth/project.json`

- [ ] **Step 1: Install `@auth0/angular-jwt`**

```bash
cd /Users/jcshin/dev/cl/carelever_assessment_ui
pnpm add @auth0/angular-jwt
```

Verify the version range was added under `dependencies` in `package.json`.

- [ ] **Step 2: Add a `test` target to `libs/auth/project.json`**

Replace the file contents with:

```json
{
  "name": "auth",
  "$schema": "../../node_modules/nx/schemas/project-schema.json",
  "sourceRoot": "libs/auth/src",
  "prefix": "lib",
  "projectType": "library",
  "tags": [],
  "targets": {
    "lint": {
      "executor": "@nx/eslint:lint"
    },
    "test": {
      "executor": "@nx/vite:test",
      "outputs": ["{options.reportsDirectory}"],
      "options": {
        "reportsDirectory": "../../coverage/libs/auth"
      }
    }
  }
}
```

- [ ] **Step 3: Verify Vitest runs (no specs yet, so it should pass with 0 tests)**

```bash
pnpm nx test auth
```

Expected: exits 0 with "No test files found" or similar.

- [ ] **Step 4: Commit**

```bash
git add package.json pnpm-lock.yaml libs/auth/project.json
git commit -m "chore(auth): add @auth0/angular-jwt and Vitest test target"
```

---

## Task 1: Claims model + auth config (DI tokens, storage keys, types)

**Files:**

- Create: `libs/auth/src/lib/claims.model.ts`
- Create: `libs/auth/src/lib/auth.config.ts`

These are pure types/constants. No tests needed — they have no behavior to verify.

- [ ] **Step 1: Create `libs/auth/src/lib/claims.model.ts`**

```ts
export type Classification = "internal" | "external" | "affiliate";

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

export type LoginResult = { status: "success" } | { status: "otp_required" };
```

- [ ] **Step 2: Create `libs/auth/src/lib/auth.config.ts`**

```ts
import { InjectionToken } from "@angular/core";

export const AUTH_SERVICE_BASE_URL = new InjectionToken<string>(
  "AUTH_SERVICE_BASE_URL",
);
export const AUTH_LEGACY_BASE_URL = new InjectionToken<string>(
  "AUTH_LEGACY_BASE_URL",
);

export const AUTH_TOKEN_KEY = "auth_token";
export const OTP_CONFIRMATION_TOKEN_KEY = "otp_confirmation_token";
```

- [ ] **Step 3: Verify types compile**

```bash
pnpm nx build auth || true   # build target may not exist; run typecheck via lint instead
pnpm nx lint auth
```

Expected: lint passes (or fails only on style — no type errors).

- [ ] **Step 4: Commit**

```bash
git add libs/auth/src/lib/claims.model.ts libs/auth/src/lib/auth.config.ts
git commit -m "feat(auth): add claims model and DI tokens"
```

---

## Task 2: AuthService — TDD

The token state holder + login/logout. Reads `localStorage` on construction; signals reflect token presence + decoded claims.

**Files:**

- Create: `libs/auth/src/lib/auth.service.spec.ts`
- Create: `libs/auth/src/lib/auth.service.ts`

- [ ] **Step 1: Write the failing spec**

```ts
// libs/auth/src/lib/auth.service.spec.ts
import { TestBed } from "@angular/core/testing";
import {
  HttpTestingController,
  provideHttpClientTesting,
} from "@angular/common/http/testing";
import { provideHttpClient } from "@angular/common/http";
import { JwtHelperService } from "@auth0/angular-jwt";
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { AuthService } from "./auth.service";
import {
  AUTH_LEGACY_BASE_URL,
  AUTH_SERVICE_BASE_URL,
  AUTH_TOKEN_KEY,
  OTP_CONFIRMATION_TOKEN_KEY,
} from "./auth.config";

const AUTH_URL = "https://auth.test";
const LEGACY_URL = "https://legacy.test";

// Helper: build a fake JWT with payload `{ user_id, classification, is_internal, exp, ... }`
function makeJwt(payload: Record<string, unknown>): string {
  const b64 = (s: string) =>
    btoa(s).replace(/=+$/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  return `header.${b64(JSON.stringify(payload))}.sig`;
}

describe("AuthService", () => {
  let service: AuthService;
  let http: HttpTestingController;

  beforeEach(() => {
    localStorage.clear();
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        JwtHelperService,
        { provide: AUTH_SERVICE_BASE_URL, useValue: AUTH_URL },
        { provide: AUTH_LEGACY_BASE_URL, useValue: LEGACY_URL },
      ],
    });
    service = TestBed.inject(AuthService);
    http = TestBed.inject(HttpTestingController);
  });

  afterEach(() => http.verify());

  it("seeds token signal from localStorage on construction", () => {
    localStorage.setItem(AUTH_TOKEN_KEY, "pre-existing");
    // Re-create service to pick up the seed
    const fresh = TestBed.runInInjectionContext(() => new AuthService());
    expect(fresh.token()).toBe("pre-existing");
  });

  it("login success writes AUTH_TOKEN_KEY and returns success result", () => {
    const jwt = makeJwt({
      user_id: "u1",
      classification: "internal",
      is_internal: true,
      exp: Math.floor(Date.now() / 1000) + 3600,
    });
    let result: { status: string } | undefined;
    service
      .login("internal", "jc@kinnect", "pw")
      .subscribe((r) => (result = r));

    const req = http.expectOne(`${AUTH_URL}/internal/authenticate`);
    expect(req.request.method).toBe("POST");
    expect(req.request.body).toEqual({ login: "jc@kinnect", password: "pw" });
    expect(req.request.withCredentials).toBe(true);
    req.flush({ data: { loginAttempt: "success", token: jwt } });

    expect(result).toEqual({ status: "success" });
    expect(localStorage.getItem(AUTH_TOKEN_KEY)).toBe(jwt);
    expect(service.token()).toBe(jwt);
  });

  it("login otp_required writes OTP_CONFIRMATION_TOKEN_KEY and returns otp_required", () => {
    const pre = makeJwt({
      user_id: "u1",
      exp: Math.floor(Date.now() / 1000) + 600,
    });
    let result: { status: string } | undefined;
    service.login("external", "a@b.com", "pw").subscribe((r) => (result = r));

    const req = http.expectOne(`${AUTH_URL}/external/authenticate`);
    req.flush({ data: { loginAttempt: "otp_required", token: pre } });

    expect(result).toEqual({ status: "otp_required" });
    expect(localStorage.getItem(OTP_CONFIRMATION_TOKEN_KEY)).toBe(pre);
    expect(localStorage.getItem(AUTH_TOKEN_KEY)).toBeNull();
  });

  it("logout clears both keys and resets the token signal", () => {
    localStorage.setItem(AUTH_TOKEN_KEY, "a");
    localStorage.setItem(OTP_CONFIRMATION_TOKEN_KEY, "b");
    service.logout();
    expect(localStorage.getItem(AUTH_TOKEN_KEY)).toBeNull();
    expect(localStorage.getItem(OTP_CONFIRMATION_TOKEN_KEY)).toBeNull();
    expect(service.token()).toBeNull();
  });

  it("claims signal decodes a valid JWT", () => {
    const jwt = makeJwt({
      user_id: "u1",
      classification: "internal",
      is_internal: true,
      email: "a@b.com",
      first_name: "A",
      last_name: "B",
      exp: Math.floor(Date.now() / 1000) + 3600,
    });
    localStorage.setItem(AUTH_TOKEN_KEY, jwt);
    const fresh = TestBed.runInInjectionContext(() => new AuthService());
    expect(fresh.claims()?.user_id).toBe("u1");
    expect(fresh.classification()).toBe("internal");
    expect(fresh.isInternal()).toBe(true);
  });

  it("claims returns null for malformed token", () => {
    localStorage.setItem(AUTH_TOKEN_KEY, "not-a-jwt");
    const fresh = TestBed.runInInjectionContext(() => new AuthService());
    expect(fresh.claims()).toBeNull();
    expect(fresh.isLoggedIn()).toBe(false);
  });

  it("isLoggedIn is false for expired token", () => {
    const expired = makeJwt({
      user_id: "u1",
      classification: "internal",
      is_internal: false,
      exp: Math.floor(Date.now() / 1000) - 60,
    });
    localStorage.setItem(AUTH_TOKEN_KEY, expired);
    const fresh = TestBed.runInInjectionContext(() => new AuthService());
    expect(fresh.isLoggedIn()).toBe(false);
  });
});
```

- [ ] **Step 2: Run the spec to confirm it fails**

```bash
pnpm nx test auth
```

Expected: FAIL — `auth.service.ts` not found.

- [ ] **Step 3: Implement `libs/auth/src/lib/auth.service.ts`**

```ts
import { computed, inject, Injectable, signal } from "@angular/core";
import { HttpClient } from "@angular/common/http";
import { Observable, map, tap } from "rxjs";
import { JwtHelperService } from "@auth0/angular-jwt";
import {
  AUTH_SERVICE_BASE_URL,
  AUTH_TOKEN_KEY,
  OTP_CONFIRMATION_TOKEN_KEY,
} from "./auth.config";
import type { Classification, JwtClaims, LoginResult } from "./claims.model";

interface AuthenticateResponse {
  data: { loginAttempt: "success" | "otp_required"; token: string };
}

@Injectable({ providedIn: "root" })
export class AuthService {
  private http = inject(HttpClient);
  private authBaseUrl = inject(AUTH_SERVICE_BASE_URL);
  private jwt = inject(JwtHelperService);

  private readonly tokenSignal = signal<string | null>(
    localStorage.getItem(AUTH_TOKEN_KEY),
  );

  readonly token = this.tokenSignal.asReadonly();

  readonly claims = computed<JwtClaims | null>(() => {
    const t = this.tokenSignal();
    if (!t) return null;
    try {
      return this.jwt.decodeToken<JwtClaims>(t) ?? null;
    } catch {
      return null;
    }
  });

  readonly classification = computed<Classification | null>(
    () => this.claims()?.classification ?? null,
  );

  readonly isInternal = computed(() => this.claims()?.is_internal === true);

  readonly isLoggedIn = computed(() => {
    const t = this.tokenSignal();
    if (!t) return false;
    try {
      return !this.jwt.isTokenExpired(t);
    } catch {
      return false;
    }
  });

  login(
    classification: Classification,
    login: string,
    password: string,
  ): Observable<LoginResult> {
    return this.http
      .post<AuthenticateResponse>(
        `${this.authBaseUrl}/${classification}/authenticate`,
        { login, password },
        { withCredentials: true },
      )
      .pipe(
        tap((res) => {
          if (res.data.loginAttempt === "success") {
            localStorage.setItem(AUTH_TOKEN_KEY, res.data.token);
            this.tokenSignal.set(res.data.token);
          } else {
            localStorage.setItem(OTP_CONFIRMATION_TOKEN_KEY, res.data.token);
          }
        }),
        map((res) => ({ status: res.data.loginAttempt }) as LoginResult),
      );
  }

  logout(): void {
    localStorage.removeItem(AUTH_TOKEN_KEY);
    localStorage.removeItem(OTP_CONFIRMATION_TOKEN_KEY);
    this.tokenSignal.set(null);
  }

  /** Internal use by OtpService when OTP confirms. */
  setToken(token: string): void {
    localStorage.setItem(AUTH_TOKEN_KEY, token);
    localStorage.removeItem(OTP_CONFIRMATION_TOKEN_KEY);
    this.tokenSignal.set(token);
  }
}
```

- [ ] **Step 4: Run the spec — should pass**

```bash
pnpm nx test auth
```

Expected: PASS for all `AuthService` tests.

- [ ] **Step 5: Commit**

```bash
git add libs/auth/src/lib/auth.service.ts libs/auth/src/lib/auth.service.spec.ts
git commit -m "feat(auth): add AuthService with token state signals and login flow"
```

---

## Task 3: OtpService — TDD

Reads pre-OTP token from `localStorage`, decodes `user_id`, posts to legacy host with custom `Authentication:` header.

**Files:**

- Create: `libs/auth/src/lib/otp.service.spec.ts`
- Create: `libs/auth/src/lib/otp.service.ts`

- [ ] **Step 1: Write the failing spec**

```ts
// libs/auth/src/lib/otp.service.spec.ts
import { TestBed } from "@angular/core/testing";
import {
  HttpTestingController,
  provideHttpClientTesting,
} from "@angular/common/http/testing";
import { provideHttpClient } from "@angular/common/http";
import { JwtHelperService } from "@auth0/angular-jwt";
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { OtpService } from "./otp.service";
import { AuthService } from "./auth.service";
import {
  AUTH_LEGACY_BASE_URL,
  AUTH_SERVICE_BASE_URL,
  AUTH_TOKEN_KEY,
  OTP_CONFIRMATION_TOKEN_KEY,
} from "./auth.config";

const AUTH_URL = "https://auth.test";
const LEGACY_URL = "https://legacy.test";

function makeJwt(payload: Record<string, unknown>): string {
  const b64 = (s: string) =>
    btoa(s).replace(/=+$/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  return `header.${b64(JSON.stringify(payload))}.sig`;
}

describe("OtpService", () => {
  let service: OtpService;
  let http: HttpTestingController;
  const preToken = makeJwt({ user_id: "u1", exp: 9999999999 });

  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem(OTP_CONFIRMATION_TOKEN_KEY, preToken);
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        JwtHelperService,
        { provide: AUTH_SERVICE_BASE_URL, useValue: AUTH_URL },
        { provide: AUTH_LEGACY_BASE_URL, useValue: LEGACY_URL },
      ],
    });
    service = TestBed.inject(OtpService);
    http = TestBed.inject(HttpTestingController);
  });

  afterEach(() => http.verify());

  it("requestOtp posts user_id and Authentication header", () => {
    service.requestOtp("internal").subscribe();
    const req = http.expectOne(
      `${LEGACY_URL}/authentication/internal/request_otp`,
    );
    expect(req.request.method).toBe("POST");
    expect(req.request.body).toEqual({ user_id: "u1" });
    expect(req.request.headers.get("Authentication")).toBe(preToken);
    expect(req.request.withCredentials).toBe(true);
    req.flush({});
  });

  it("authenticateOtp posts user_id + otp, swaps tokens on success", () => {
    const finalJwt = makeJwt({
      user_id: "u1",
      classification: "internal",
      is_internal: true,
      exp: Math.floor(Date.now() / 1000) + 3600,
    });
    let completed = false;
    service
      .authenticateOtp("internal", "123456")
      .subscribe(() => (completed = true));

    const req = http.expectOne(
      `${LEGACY_URL}/authentication/internal/authenticate_otp`,
    );
    expect(req.request.body).toEqual({ user_id: "u1", otp: "123456" });
    expect(req.request.headers.get("Authentication")).toBe(preToken);
    req.flush({ data: finalJwt });

    expect(completed).toBe(true);
    expect(localStorage.getItem(AUTH_TOKEN_KEY)).toBe(finalJwt);
    expect(localStorage.getItem(OTP_CONFIRMATION_TOKEN_KEY)).toBeNull();
    expect(TestBed.inject(AuthService).token()).toBe(finalJwt);
  });

  it("throws when pre-OTP token missing", () => {
    localStorage.removeItem(OTP_CONFIRMATION_TOKEN_KEY);
    expect(() => service.requestOtp("internal").subscribe()).toThrow();
  });

  it("uses external classification for /external/authenticate_otp", () => {
    service.authenticateOtp("external", "999999").subscribe();
    const req = http.expectOne(
      `${LEGACY_URL}/authentication/external/authenticate_otp`,
    );
    req.flush({ data: makeJwt({ user_id: "u1", exp: 9999999999 }) });
  });
});
```

- [ ] **Step 2: Run — should fail (no `OtpService`)**

```bash
pnpm nx test auth
```

Expected: FAIL.

- [ ] **Step 3: Implement `libs/auth/src/lib/otp.service.ts`**

```ts
import { HttpClient, HttpHeaders } from "@angular/common/http";
import { inject, Injectable } from "@angular/core";
import { JwtHelperService } from "@auth0/angular-jwt";
import { Observable, map, tap } from "rxjs";
import { AuthService } from "./auth.service";
import {
  AUTH_LEGACY_BASE_URL,
  OTP_CONFIRMATION_TOKEN_KEY,
} from "./auth.config";
import type { Classification } from "./claims.model";

interface AuthenticateOtpResponse {
  data: string;
}

@Injectable({ providedIn: "root" })
export class OtpService {
  private http = inject(HttpClient);
  private legacyUrl = inject(AUTH_LEGACY_BASE_URL);
  private jwt = inject(JwtHelperService);
  private auth = inject(AuthService);

  requestOtp(classification: Classification): Observable<void> {
    const { token, userId } = this.preTokenContext();
    return this.http
      .post(
        `${this.legacyUrl}/authentication/${classification}/request_otp`,
        { user_id: userId },
        {
          headers: new HttpHeaders({ Authentication: token }),
          withCredentials: true,
        },
      )
      .pipe(map(() => void 0));
  }

  authenticateOtp(
    classification: Classification,
    otp: string,
  ): Observable<void> {
    const { token, userId } = this.preTokenContext();
    return this.http
      .post<AuthenticateOtpResponse>(
        `${this.legacyUrl}/authentication/${classification}/authenticate_otp`,
        { user_id: userId, otp },
        {
          headers: new HttpHeaders({ Authentication: token }),
          withCredentials: true,
        },
      )
      .pipe(
        tap((res) => this.auth.setToken(res.data)),
        map(() => void 0),
      );
  }

  private preTokenContext(): { token: string; userId: string } {
    const token = localStorage.getItem(OTP_CONFIRMATION_TOKEN_KEY);
    if (!token) {
      throw new Error("OTP confirmation token missing — call login() first.");
    }
    const payload = this.jwt.decodeToken<{ user_id: string }>(token);
    if (!payload?.user_id) {
      throw new Error("Pre-OTP token missing user_id claim.");
    }
    return { token, userId: payload.user_id };
  }
}
```

- [ ] **Step 4: Run — should pass**

```bash
pnpm nx test auth
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add libs/auth/src/lib/otp.service.ts libs/auth/src/lib/otp.service.spec.ts
git commit -m "feat(auth): add OtpService for legacy-host OTP flow"
```

---

## Task 4: tokenInterceptor — TDD

Attaches `Authorization: Bearer <token>` to requests targeting `API_BASE_URL`. Skips both auth hosts entirely.

**Files:**

- Create: `libs/auth/src/lib/token.interceptor.spec.ts`
- Create: `libs/auth/src/lib/token.interceptor.ts`

- [ ] **Step 1: Write the failing spec**

```ts
// libs/auth/src/lib/token.interceptor.spec.ts
import { TestBed } from "@angular/core/testing";
import {
  provideHttpClient,
  withInterceptors,
  HttpClient,
} from "@angular/common/http";
import {
  HttpTestingController,
  provideHttpClientTesting,
} from "@angular/common/http/testing";
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { API_BASE_URL } from "@org/api";
import { tokenInterceptor } from "./token.interceptor";
import {
  AUTH_LEGACY_BASE_URL,
  AUTH_SERVICE_BASE_URL,
  AUTH_TOKEN_KEY,
} from "./auth.config";

const API_URL = "https://api.test";
const AUTH_URL = "https://auth.test";
const LEGACY_URL = "https://legacy.test";

describe("tokenInterceptor", () => {
  let http: HttpClient;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    localStorage.clear();
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(withInterceptors([tokenInterceptor])),
        provideHttpClientTesting(),
        { provide: API_BASE_URL, useValue: API_URL },
        { provide: AUTH_SERVICE_BASE_URL, useValue: AUTH_URL },
        { provide: AUTH_LEGACY_BASE_URL, useValue: LEGACY_URL },
      ],
    });
    http = TestBed.inject(HttpClient);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpMock.verify());

  it("attaches Bearer token to API_BASE_URL requests", () => {
    localStorage.setItem(AUTH_TOKEN_KEY, "abc");
    http.get(`${API_URL}/v1/me`).subscribe();
    const req = httpMock.expectOne(`${API_URL}/v1/me`);
    expect(req.request.headers.get("Authorization")).toBe("Bearer abc");
    req.flush({});
  });

  it("does NOT attach token to AUTH_SERVICE_BASE_URL requests", () => {
    localStorage.setItem(AUTH_TOKEN_KEY, "abc");
    http.post(`${AUTH_URL}/internal/authenticate`, {}).subscribe();
    const req = httpMock.expectOne(`${AUTH_URL}/internal/authenticate`);
    expect(req.request.headers.has("Authorization")).toBe(false);
    req.flush({});
  });

  it("does NOT attach token to AUTH_LEGACY_BASE_URL requests", () => {
    localStorage.setItem(AUTH_TOKEN_KEY, "abc");
    http
      .post(`${LEGACY_URL}/authentication/internal/request_otp`, {})
      .subscribe();
    const req = httpMock.expectOne(
      `${LEGACY_URL}/authentication/internal/request_otp`,
    );
    expect(req.request.headers.has("Authorization")).toBe(false);
    req.flush({});
  });

  it("passes through API_BASE_URL request when no token present", () => {
    http.get(`${API_URL}/v1/public`).subscribe();
    const req = httpMock.expectOne(`${API_URL}/v1/public`);
    expect(req.request.headers.has("Authorization")).toBe(false);
    req.flush({});
  });
});
```

- [ ] **Step 2: Run — should fail**

```bash
pnpm nx test auth
```

Expected: FAIL.

- [ ] **Step 3: Implement `libs/auth/src/lib/token.interceptor.ts`**

```ts
import { HttpInterceptorFn } from "@angular/common/http";
import { inject } from "@angular/core";
import {
  AUTH_LEGACY_BASE_URL,
  AUTH_SERVICE_BASE_URL,
  AUTH_TOKEN_KEY,
} from "./auth.config";

export const tokenInterceptor: HttpInterceptorFn = (req, next) => {
  const authBaseUrl = inject(AUTH_SERVICE_BASE_URL);
  const legacyBaseUrl = inject(AUTH_LEGACY_BASE_URL);

  if (req.url.startsWith(authBaseUrl) || req.url.startsWith(legacyBaseUrl)) {
    return next(req);
  }

  const token = localStorage.getItem(AUTH_TOKEN_KEY);
  if (!token) return next(req);

  return next(req.clone({ setHeaders: { Authorization: `Bearer ${token}` } }));
};
```

- [ ] **Step 4: Run — should pass**

```bash
pnpm nx test auth
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add libs/auth/src/lib/token.interceptor.ts libs/auth/src/lib/token.interceptor.spec.ts
git commit -m "feat(auth): add tokenInterceptor"
```

---

## Task 5: errorInterceptor — TDD

Catches 401 from API_BASE_URL → logs out + redirects to `/login`. Auth-service 401s pass through (so login form can display them).

**Files:**

- Create: `libs/auth/src/lib/error.interceptor.spec.ts`
- Create: `libs/auth/src/lib/error.interceptor.ts`

- [ ] **Step 1: Write the failing spec**

```ts
// libs/auth/src/lib/error.interceptor.spec.ts
import { TestBed } from "@angular/core/testing";
import {
  provideHttpClient,
  withInterceptors,
  HttpClient,
} from "@angular/common/http";
import {
  HttpTestingController,
  provideHttpClientTesting,
} from "@angular/common/http/testing";
import { Router } from "@angular/router";
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { JwtHelperService } from "@auth0/angular-jwt";
import { API_BASE_URL } from "@org/api";
import { errorInterceptor } from "./error.interceptor";
import { AuthService } from "./auth.service";
import { AUTH_LEGACY_BASE_URL, AUTH_SERVICE_BASE_URL } from "./auth.config";

const API_URL = "https://api.test";

describe("errorInterceptor", () => {
  let http: HttpClient;
  let httpMock: HttpTestingController;
  let routerSpy: { navigate: ReturnType<typeof vi.fn> };

  beforeEach(() => {
    localStorage.clear();
    routerSpy = { navigate: vi.fn() };
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(withInterceptors([errorInterceptor])),
        provideHttpClientTesting(),
        JwtHelperService,
        { provide: Router, useValue: routerSpy },
        { provide: API_BASE_URL, useValue: API_URL },
        { provide: AUTH_SERVICE_BASE_URL, useValue: "https://auth.test" },
        { provide: AUTH_LEGACY_BASE_URL, useValue: "https://legacy.test" },
      ],
    });
    http = TestBed.inject(HttpClient);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpMock.verify());

  it("logs out and redirects on API 401", () => {
    const auth = TestBed.inject(AuthService);
    const logoutSpy = vi.spyOn(auth, "logout");
    http.get(`${API_URL}/v1/me`).subscribe({ error: () => undefined });
    httpMock.expectOne(`${API_URL}/v1/me`).flush("nope", {
      status: 401,
      statusText: "Unauthorized",
    });
    expect(logoutSpy).toHaveBeenCalled();
    expect(routerSpy.navigate).toHaveBeenCalledWith(["/login"]);
  });

  it("does NOT redirect on auth-service 401", () => {
    http
      .post("https://auth.test/internal/authenticate", {})
      .subscribe({ error: () => undefined });
    httpMock
      .expectOne("https://auth.test/internal/authenticate")
      .flush("bad", { status: 401, statusText: "Unauthorized" });
    expect(routerSpy.navigate).not.toHaveBeenCalled();
  });

  it("passes through non-401 errors", () => {
    http.get(`${API_URL}/v1/x`).subscribe({ error: () => undefined });
    httpMock
      .expectOne(`${API_URL}/v1/x`)
      .flush("boom", { status: 500, statusText: "Server Error" });
    expect(routerSpy.navigate).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run — should fail**

```bash
pnpm nx test auth
```

Expected: FAIL.

- [ ] **Step 3: Implement `libs/auth/src/lib/error.interceptor.ts`**

```ts
import { HttpErrorResponse, HttpInterceptorFn } from "@angular/common/http";
import { inject } from "@angular/core";
import { Router } from "@angular/router";
import { catchError, throwError } from "rxjs";
import { API_BASE_URL } from "@org/api";
import { AuthService } from "./auth.service";

export const errorInterceptor: HttpInterceptorFn = (req, next) => {
  const router = inject(Router);
  const auth = inject(AuthService);
  const apiBaseUrl = inject(API_BASE_URL);

  return next(req).pipe(
    catchError((err: HttpErrorResponse) => {
      if (err.status === 401 && req.url.startsWith(apiBaseUrl)) {
        auth.logout();
        router.navigate(["/login"]);
      }
      return throwError(() => err);
    }),
  );
};
```

- [ ] **Step 4: Run — should pass**

```bash
pnpm nx test auth
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add libs/auth/src/lib/error.interceptor.ts libs/auth/src/lib/error.interceptor.spec.ts
git commit -m "feat(auth): add errorInterceptor for 401 redirect"
```

---

## Task 6: authGuard — TDD (rewrite existing)

Replace existing stub. Returns true if logged-in, else `UrlTree('/login')`.

**Files:**

- Modify: `libs/auth/src/lib/auth.guard.ts`
- Create: `libs/auth/src/lib/auth.guard.spec.ts`

- [ ] **Step 1: Write the failing spec**

```ts
// libs/auth/src/lib/auth.guard.spec.ts
import { TestBed, runInInjectionContext } from "@angular/core/testing";
import { Router, UrlTree } from "@angular/router";
import { describe, it, expect, beforeEach, vi } from "vitest";
import { JwtHelperService } from "@auth0/angular-jwt";
import { provideHttpClient } from "@angular/common/http";
import { provideHttpClientTesting } from "@angular/common/http/testing";
import { authGuard } from "./auth.guard";
import { AuthService } from "./auth.service";
import { AUTH_LEGACY_BASE_URL, AUTH_SERVICE_BASE_URL } from "./auth.config";

describe("authGuard", () => {
  let createUrlTreeSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    localStorage.clear();
    createUrlTreeSpy = vi.fn(() => ({}) as UrlTree);
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        JwtHelperService,
        { provide: Router, useValue: { createUrlTree: createUrlTreeSpy } },
        { provide: AUTH_SERVICE_BASE_URL, useValue: "x" },
        { provide: AUTH_LEGACY_BASE_URL, useValue: "y" },
      ],
    });
  });

  it("returns true when logged in", () => {
    const auth = TestBed.inject(AuthService);
    vi.spyOn(auth, "isLoggedIn").mockReturnValue(true);
    const result = runInInjectionContext(TestBed.inject(Object) as never, () =>
      authGuard({} as never, {} as never),
    );
    expect(result).toBe(true);
  });

  it("returns UrlTree to /login when not logged in", () => {
    const auth = TestBed.inject(AuthService);
    vi.spyOn(auth, "isLoggedIn").mockReturnValue(false);
    runInInjectionContext(TestBed.inject(Object) as never, () =>
      authGuard({} as never, {} as never),
    );
    expect(createUrlTreeSpy).toHaveBeenCalledWith(["/login"]);
  });
});
```

Note: if `runInInjectionContext` complains about the `TestBed.inject(Object)` placeholder, replace with `TestBed.runInInjectionContext(() => authGuard(...))` instead — both are supported, the second is cleaner.

- [ ] **Step 2: Run — should fail (signature change)**

```bash
pnpm nx test auth
```

Expected: FAIL.

- [ ] **Step 3: Replace `libs/auth/src/lib/auth.guard.ts`**

```ts
import { inject } from "@angular/core";
import { CanActivateFn, Router } from "@angular/router";
import { AuthService } from "./auth.service";

export const authGuard: CanActivateFn = () => {
  const auth = inject(AuthService);
  const router = inject(Router);
  return auth.isLoggedIn() ? true : router.createUrlTree(["/login"]);
};
```

- [ ] **Step 4: Run — should pass**

```bash
pnpm nx test auth
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add libs/auth/src/lib/auth.guard.ts libs/auth/src/lib/auth.guard.spec.ts
git commit -m "refactor(auth): rewrite authGuard against new AuthService"
```

---

## Task 7: classificationGuard — TDD

Factory that returns a `CanActivateFn` admitting only the given classifications.

**Files:**

- Create: `libs/auth/src/lib/classification.guard.ts`
- Create: `libs/auth/src/lib/classification.guard.spec.ts`

- [ ] **Step 1: Write the failing spec**

```ts
// libs/auth/src/lib/classification.guard.spec.ts
import { TestBed } from "@angular/core/testing";
import { Router, UrlTree } from "@angular/router";
import { describe, it, expect, beforeEach, vi } from "vitest";
import { JwtHelperService } from "@auth0/angular-jwt";
import { provideHttpClient } from "@angular/common/http";
import { provideHttpClientTesting } from "@angular/common/http/testing";
import { classificationGuard } from "./classification.guard";
import { AuthService } from "./auth.service";
import { AUTH_LEGACY_BASE_URL, AUTH_SERVICE_BASE_URL } from "./auth.config";

describe("classificationGuard", () => {
  let urlTreeSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    localStorage.clear();
    urlTreeSpy = vi.fn(() => ({}) as UrlTree);
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        JwtHelperService,
        { provide: Router, useValue: { createUrlTree: urlTreeSpy } },
        { provide: AUTH_SERVICE_BASE_URL, useValue: "x" },
        { provide: AUTH_LEGACY_BASE_URL, useValue: "y" },
      ],
    });
  });

  it("admits matching classification", () => {
    const auth = TestBed.inject(AuthService);
    vi.spyOn(auth, "classification").mockReturnValue("internal");
    const result = TestBed.runInInjectionContext(() =>
      classificationGuard(["internal"])({} as never, {} as never),
    );
    expect(result).toBe(true);
  });

  it("blocks mismatched classification", () => {
    const auth = TestBed.inject(AuthService);
    vi.spyOn(auth, "classification").mockReturnValue("external");
    TestBed.runInInjectionContext(() =>
      classificationGuard(["internal"])({} as never, {} as never),
    );
    expect(urlTreeSpy).toHaveBeenCalledWith(["/login"]);
  });

  it("blocks when classification is null", () => {
    const auth = TestBed.inject(AuthService);
    vi.spyOn(auth, "classification").mockReturnValue(null);
    TestBed.runInInjectionContext(() =>
      classificationGuard(["internal"])({} as never, {} as never),
    );
    expect(urlTreeSpy).toHaveBeenCalledWith(["/login"]);
  });
});
```

- [ ] **Step 2: Run — should fail**

```bash
pnpm nx test auth
```

Expected: FAIL.

- [ ] **Step 3: Implement `libs/auth/src/lib/classification.guard.ts`**

```ts
import { inject } from "@angular/core";
import { CanActivateFn, Router } from "@angular/router";
import { AuthService } from "./auth.service";
import type { Classification } from "./claims.model";

export const classificationGuard =
  (allowed: Classification[]): CanActivateFn =>
  () => {
    const auth = inject(AuthService);
    const router = inject(Router);
    const c = auth.classification();
    return c !== null && allowed.includes(c)
      ? true
      : router.createUrlTree(["/login"]);
  };
```

- [ ] **Step 4: Run — should pass**

```bash
pnpm nx test auth
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add libs/auth/src/lib/classification.guard.ts libs/auth/src/lib/classification.guard.spec.ts
git commit -m "feat(auth): add classificationGuard factory"
```

---

## Task 8: OtpComponent — TDD

Reactive form for 6-digit OTP. Reads classification + successRedirect from route data. Has a 30-second cooldown on the resend button.

**Files:**

- Create: `libs/auth/src/lib/components/otp/otp.component.ts`
- Create: `libs/auth/src/lib/components/otp/otp.component.html`
- Create: `libs/auth/src/lib/components/otp/otp.component.spec.ts`

- [ ] **Step 1: Write the failing spec**

```ts
// libs/auth/src/lib/components/otp/otp.component.spec.ts
import { TestBed, ComponentFixture } from "@angular/core/testing";
import { ActivatedRoute, Router } from "@angular/router";
import { provideHttpClient } from "@angular/common/http";
import { provideHttpClientTesting } from "@angular/common/http/testing";
import { JwtHelperService } from "@auth0/angular-jwt";
import { describe, it, expect, beforeEach, vi } from "vitest";
import { of, throwError } from "rxjs";
import { OtpComponent } from "./otp.component";
import { OtpService } from "../../otp.service";
import { AUTH_LEGACY_BASE_URL, AUTH_SERVICE_BASE_URL } from "../../auth.config";

describe("OtpComponent", () => {
  let fixture: ComponentFixture<OtpComponent>;
  let component: OtpComponent;
  let otpServiceSpy: {
    authenticateOtp: ReturnType<typeof vi.fn>;
    requestOtp: ReturnType<typeof vi.fn>;
  };
  let routerSpy: { navigate: ReturnType<typeof vi.fn> };

  beforeEach(() => {
    otpServiceSpy = {
      authenticateOtp: vi.fn(() => of(void 0)),
      requestOtp: vi.fn(() => of(void 0)),
    };
    routerSpy = { navigate: vi.fn() };

    TestBed.configureTestingModule({
      imports: [OtpComponent],
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        JwtHelperService,
        { provide: OtpService, useValue: otpServiceSpy },
        { provide: Router, useValue: routerSpy },
        {
          provide: ActivatedRoute,
          useValue: {
            snapshot: {
              data: {
                classification: "internal",
                successRedirect: "/dashboard",
              },
            },
          },
        },
        { provide: AUTH_SERVICE_BASE_URL, useValue: "x" },
        { provide: AUTH_LEGACY_BASE_URL, useValue: "y" },
      ],
    });
    fixture = TestBed.createComponent(OtpComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it("submits the OTP and navigates on success", () => {
    component.form.setValue({ code: "123456" });
    component.submit();
    expect(otpServiceSpy.authenticateOtp).toHaveBeenCalledWith(
      "internal",
      "123456",
    );
    expect(routerSpy.navigate).toHaveBeenCalledWith(["/dashboard"]);
  });

  it("shows error on failed submission", () => {
    otpServiceSpy.authenticateOtp.mockReturnValueOnce(
      throwError(() => ({ error: { message: "Bad code" } })),
    );
    component.form.setValue({ code: "999999" });
    component.submit();
    expect(component.error()).toBeTruthy();
    expect(routerSpy.navigate).not.toHaveBeenCalled();
  });

  it("blocks submission when form invalid", () => {
    component.form.setValue({ code: "12" }); // too short
    component.submit();
    expect(otpServiceSpy.authenticateOtp).not.toHaveBeenCalled();
  });

  it("resend calls requestOtp and starts cooldown", () => {
    vi.useFakeTimers();
    component.resend();
    expect(otpServiceSpy.requestOtp).toHaveBeenCalledWith("internal");
    expect(component.resendCooldown()).toBeGreaterThan(0);
    vi.advanceTimersByTime(31_000);
    expect(component.resendCooldown()).toBe(0);
    vi.useRealTimers();
  });
});
```

- [ ] **Step 2: Run — should fail**

```bash
pnpm nx test auth
```

Expected: FAIL.

- [ ] **Step 3: Create `libs/auth/src/lib/components/otp/otp.component.ts`**

```ts
import { Component, inject, signal, OnInit, OnDestroy } from "@angular/core";
import { ActivatedRoute, Router } from "@angular/router";
import {
  FormControl,
  FormGroup,
  ReactiveFormsModule,
  Validators,
} from "@angular/forms";
import { OtpService } from "../../otp.service";
import type { Classification } from "../../claims.model";

const RESEND_COOLDOWN_SECONDS = 30;

@Component({
  selector: "lib-otp",
  standalone: true,
  imports: [ReactiveFormsModule],
  templateUrl: "./otp.component.html",
})
export class OtpComponent implements OnInit, OnDestroy {
  private otp = inject(OtpService);
  private router = inject(Router);
  private route = inject(ActivatedRoute);

  private classification!: Classification;
  private successRedirect!: string;

  form = new FormGroup({
    code: new FormControl("", {
      nonNullable: true,
      validators: [Validators.required, Validators.pattern(/^\d{6}$/)],
    }),
  });

  readonly error = signal<string | null>(null);
  readonly resendCooldown = signal(0);

  private intervalId: ReturnType<typeof setInterval> | null = null;

  ngOnInit(): void {
    this.classification = this.route.snapshot.data["classification"];
    this.successRedirect = this.route.snapshot.data["successRedirect"] ?? "/";
  }

  ngOnDestroy(): void {
    if (this.intervalId !== null) clearInterval(this.intervalId);
  }

  submit(): void {
    if (this.form.invalid) return;
    this.error.set(null);
    const code = this.form.controls.code.value;
    this.otp.authenticateOtp(this.classification, code).subscribe({
      next: () => this.router.navigate([this.successRedirect]),
      error: (err) =>
        this.error.set(err?.error?.message ?? "Could not verify code"),
    });
  }

  resend(): void {
    if (this.resendCooldown() > 0) return;
    this.otp.requestOtp(this.classification).subscribe({
      error: (err) =>
        this.error.set(err?.error?.message ?? "Could not resend code"),
    });
    this.startCooldown();
  }

  private startCooldown(): void {
    this.resendCooldown.set(RESEND_COOLDOWN_SECONDS);
    this.intervalId = setInterval(() => {
      const next = this.resendCooldown() - 1;
      this.resendCooldown.set(next);
      if (next <= 0 && this.intervalId !== null) {
        clearInterval(this.intervalId);
        this.intervalId = null;
      }
    }, 1000);
  }
}
```

- [ ] **Step 4: Create `libs/auth/src/lib/components/otp/otp.component.html`**

```html
<form [formGroup]="form" (ngSubmit)="submit()">
  <label>
    Verification code
    <input
      type="text"
      inputmode="numeric"
      autocomplete="one-time-code"
      maxlength="6"
      formControlName="code"
    />
  </label>

  @if (error()) {
  <p role="alert">{{ error() }}</p>
  }

  <button type="submit" [disabled]="form.invalid">Verify</button>
  <button type="button" (click)="resend()" [disabled]="resendCooldown() > 0">
    @if (resendCooldown() > 0) { Resend in {{ resendCooldown() }}s } @else {
    Resend code }
  </button>
</form>
```

- [ ] **Step 5: Run — should pass**

```bash
pnpm nx test auth
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add libs/auth/src/lib/components/otp/
git commit -m "feat(auth): add shared OtpComponent"
```

---

## Task 9: MeService stub

Minimal stub. No consumer in this PR; later PRs will flesh it out.

**Files:**

- Create: `libs/auth/src/lib/me.service.ts`

- [ ] **Step 1: Create `libs/auth/src/lib/me.service.ts`**

```ts
import { HttpClient } from "@angular/common/http";
import { inject, Injectable } from "@angular/core";
import { Observable } from "rxjs";
import { API_BASE_URL } from "@org/api";

export interface CurrentUser {
  id: string;
  email: string;
  first_name: string;
  last_name: string;
  job_title: string | null;
  primary_company_id: string | null;
  client_role: "system_admin" | "user" | null;
  role_types: string[];
  permissions: string[];
  accessible_company_ids: string[];
  accessible_site_ids: string[];
}

@Injectable({ providedIn: "root" })
export class MeService {
  private http = inject(HttpClient);
  private baseUrl = inject(API_BASE_URL);

  fetch(): Observable<CurrentUser> {
    return this.http.get<CurrentUser>(`${this.baseUrl}/v1/me`);
  }
}
```

- [ ] **Step 2: Verify lint passes**

```bash
pnpm nx lint auth
```

Expected: pass (no test for stub; consumer in later PR).

- [ ] **Step 3: Commit**

```bash
git add libs/auth/src/lib/me.service.ts
git commit -m "feat(auth): add MeService stub for /v1/me"
```

---

## Task 10: Public exports + delete old surface

Update `libs/auth/src/index.ts`. Delete obsolete files.

**Files:**

- Modify: `libs/auth/src/index.ts`
- Delete: `libs/auth/src/lib/auth/auth.service.ts`, `libs/auth/src/lib/auth/auth.css`, `libs/auth/src/lib/auth/auth.html`
- Delete: `libs/auth/src/lib/login/login.component.ts`, `libs/auth/src/lib/login/login.component.html`
- Delete: `libs/auth/src/lib/masquerade/masquerade.component.ts`, `libs/auth/src/lib/masquerade/masquerade.component.html`

- [ ] **Step 1: Replace `libs/auth/src/index.ts`**

```ts
export {
  AUTH_SERVICE_BASE_URL,
  AUTH_LEGACY_BASE_URL,
  AUTH_TOKEN_KEY,
  OTP_CONFIRMATION_TOKEN_KEY,
} from "./lib/auth.config";
export type {
  Classification,
  JwtClaims,
  LoginResult,
} from "./lib/claims.model";
export { AuthService } from "./lib/auth.service";
export { OtpService } from "./lib/otp.service";
export { MeService, type CurrentUser } from "./lib/me.service";
export { tokenInterceptor } from "./lib/token.interceptor";
export { errorInterceptor } from "./lib/error.interceptor";
export { authGuard } from "./lib/auth.guard";
export { classificationGuard } from "./lib/classification.guard";
export { OtpComponent } from "./lib/components/otp/otp.component";
```

- [ ] **Step 2: Delete the old directories**

```bash
cd /Users/jcshin/dev/cl/carelever_assessment_ui
rm -rf libs/auth/src/lib/auth libs/auth/src/lib/login libs/auth/src/lib/masquerade
```

- [ ] **Step 3: Confirm `nx test auth` and `nx lint auth` still pass**

```bash
pnpm nx test auth && pnpm nx lint auth
```

Expected: both PASS.

- [ ] **Step 4: Commit**

```bash
git add libs/auth/src/index.ts
git add -u libs/auth/src/lib/  # captures the deletions
git commit -m "refactor(auth): publish new surface, drop old LoginComponent and MasqueradeComponent"
```

---

## Task 11: Migrate libs/api — remove authInterceptor and AUTH_TOKEN_KEY

The old interceptor and storage-key constant move to `libs/auth`. `libs/api` keeps `API_BASE_URL` only.

**Files:**

- Modify: `libs/api/src/index.ts`
- Modify: `libs/api/src/lib/api.config.ts`
- Delete: `libs/api/src/lib/auth.interceptor.ts`

- [ ] **Step 1: Update `libs/api/src/lib/api.config.ts`**

```ts
import { InjectionToken } from "@angular/core";

export const API_BASE_URL = new InjectionToken<string>("API_BASE_URL");
```

- [ ] **Step 2: Update `libs/api/src/index.ts`**

```ts
export * from "./lib/api/api";
export { API_BASE_URL } from "./lib/api.config";
```

- [ ] **Step 3: Delete the old interceptor file**

```bash
rm libs/api/src/lib/auth.interceptor.ts
```

- [ ] **Step 4: Verify nothing else in the workspace imports the removed symbols**

```bash
cd /Users/jcshin/dev/cl/carelever_assessment_ui
grep -rn "from '@org/api'" --include='*.ts' | grep -E "AUTH_TOKEN_KEY|authInterceptor"
```

Expected: only `apps/internal/src/app/app.config.ts` (which we update in Task 14). If anything else surfaces, halt and discuss before proceeding.

- [ ] **Step 5: Commit**

```bash
git add libs/api/src/lib/api.config.ts libs/api/src/index.ts
git add -u libs/api/src/lib/  # captures the deletion
git commit -m "refactor(api): remove authInterceptor and AUTH_TOKEN_KEY (moved to @org/auth)"
```

---

## Task 12: apps/internal environments — add auth URLs

**Files:**

- Modify: `apps/internal/src/environments/environment.ts`
- Modify: `apps/internal/src/environments/environment.dev.ts`
- Modify: `apps/internal/src/environments/environment.staging.ts`
- Modify: `apps/internal/src/environments/environment.prod.ts`

- [ ] **Step 1: Update `apps/internal/src/environments/environment.ts`**

```ts
export const environment = {
  production: false,
  apiUrl: "http://localhost:3000/v1",
  authServiceUrl: "https://authentication-api.dev.carelever.com",
  authLegacyUrl: "https://api.dev.carelever.com",
};
```

- [ ] **Step 2: Update `apps/internal/src/environments/environment.dev.ts`**

(Read the file first; mirror its existing shape, just add the two URL keys.)

```ts
export const environment = {
  production: false,
  apiUrl: "<existing dev apiUrl>",
  authServiceUrl: "https://authentication-api.dev.carelever.com",
  authLegacyUrl: "https://api.dev.carelever.com",
};
```

- [ ] **Step 3: Update `apps/internal/src/environments/environment.staging.ts`**

```ts
export const environment = {
  production: false,
  apiUrl: "<existing staging apiUrl>",
  authServiceUrl: "https://authentication-api.staging.carelever.com",
  authLegacyUrl: "https://api.staging.carelever.com",
};
```

- [ ] **Step 4: Update `apps/internal/src/environments/environment.prod.ts`**

```ts
export const environment = {
  production: true,
  apiUrl: "<existing prod apiUrl>",
  authServiceUrl: "https://authentication-api.carelever.com",
  authLegacyUrl: "https://api.carelever.com",
};
```

- [ ] **Step 5: Build to confirm types are happy**

```bash
pnpm nx build internal --configuration=development
```

Expected: build succeeds (we haven't yet wired the new URLs, but the TS shape is consistent across env files).

- [ ] **Step 6: Commit**

```bash
git add apps/internal/src/environments/
git commit -m "chore(internal): add authServiceUrl and authLegacyUrl to environments"
```

---

## Task 13: InternalLoginComponent — TDD

Per-app login component. Form: `{ login, password }`. Routes per `LoginResult`.

**Files:**

- Create: `apps/internal/src/app/login/login.component.ts`
- Create: `apps/internal/src/app/login/login.component.html`
- Create: `apps/internal/src/app/login/login.component.spec.ts`

- [ ] **Step 1: Confirm `apps/internal` has a Vitest test target**

Check `apps/internal/project.json`. If there is **no** `test` target, add one mirroring the lib's setup. Inspect the existing target list first; if Vitest is wired through a project plugin, skip this step. If unsure, add manually:

```jsonc
"test": {
  "executor": "@nx/vite:test",
  "outputs": ["{options.reportsDirectory}"],
  "options": {
    "reportsDirectory": "../../coverage/apps/internal"
  }
}
```

…and create `apps/internal/vite.config.mts` mirroring `libs/auth/vite.config.mts` (change paths and `name`). Confirm `pnpm nx test internal` runs (will report no specs).

- [ ] **Step 2: Write the failing spec**

```ts
// apps/internal/src/app/login/login.component.spec.ts
import { TestBed, ComponentFixture } from "@angular/core/testing";
import { Router } from "@angular/router";
import { provideHttpClient } from "@angular/common/http";
import { provideHttpClientTesting } from "@angular/common/http/testing";
import { JwtHelperService } from "@auth0/angular-jwt";
import { describe, it, expect, beforeEach, vi } from "vitest";
import { of, throwError } from "rxjs";
import { AuthService } from "@org/auth";
import { AUTH_LEGACY_BASE_URL, AUTH_SERVICE_BASE_URL } from "@org/auth";
import { LoginComponent } from "./login.component";

describe("LoginComponent (internal)", () => {
  let fixture: ComponentFixture<LoginComponent>;
  let component: LoginComponent;
  let authSpy: { login: ReturnType<typeof vi.fn> };
  let routerSpy: { navigate: ReturnType<typeof vi.fn> };

  beforeEach(() => {
    authSpy = { login: vi.fn(() => of({ status: "success" })) };
    routerSpy = { navigate: vi.fn() };
    TestBed.configureTestingModule({
      imports: [LoginComponent],
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        JwtHelperService,
        { provide: AuthService, useValue: authSpy },
        { provide: Router, useValue: routerSpy },
        { provide: AUTH_SERVICE_BASE_URL, useValue: "x" },
        { provide: AUTH_LEGACY_BASE_URL, useValue: "y" },
      ],
    });
    fixture = TestBed.createComponent(LoginComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it("on success navigates to /dashboard", () => {
    component.form.setValue({ login: "jc@kinnect", password: "pw" });
    component.submit();
    expect(authSpy.login).toHaveBeenCalledWith("internal", "jc@kinnect", "pw");
    expect(routerSpy.navigate).toHaveBeenCalledWith(["/dashboard"]);
  });

  it("on otp_required navigates to /login/otp", () => {
    authSpy.login.mockReturnValueOnce(of({ status: "otp_required" }));
    component.form.setValue({ login: "jc@kinnect", password: "pw" });
    component.submit();
    expect(routerSpy.navigate).toHaveBeenCalledWith(["/login/otp"]);
  });

  it("on error shows inline message", () => {
    authSpy.login.mockReturnValueOnce(
      throwError(() => ({ error: { message: "Invalid credentials" } })),
    );
    component.form.setValue({ login: "jc@kinnect", password: "pw" });
    component.submit();
    expect(component.error()).toBe("Invalid credentials");
    expect(routerSpy.navigate).not.toHaveBeenCalled();
  });

  it("blocks submit when form invalid", () => {
    component.form.setValue({ login: "", password: "" });
    component.submit();
    expect(authSpy.login).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 3: Run — should fail (component does not exist)**

```bash
pnpm nx test internal
```

Expected: FAIL.

- [ ] **Step 4: Implement `apps/internal/src/app/login/login.component.ts`**

```ts
import { Component, inject, signal } from "@angular/core";
import { Router } from "@angular/router";
import {
  FormControl,
  FormGroup,
  ReactiveFormsModule,
  Validators,
} from "@angular/forms";
import { AuthService } from "@org/auth";

@Component({
  selector: "app-internal-login",
  standalone: true,
  imports: [ReactiveFormsModule],
  templateUrl: "./login.component.html",
})
export class LoginComponent {
  private auth = inject(AuthService);
  private router = inject(Router);

  form = new FormGroup({
    login: new FormControl("", {
      nonNullable: true,
      validators: [Validators.required],
    }),
    password: new FormControl("", {
      nonNullable: true,
      validators: [Validators.required],
    }),
  });

  readonly error = signal<string | null>(null);

  submit(): void {
    if (this.form.invalid) return;
    this.error.set(null);
    const { login, password } = this.form.getRawValue();
    this.auth.login("internal", login, password).subscribe({
      next: (result) => {
        if (result.status === "success") {
          this.router.navigate(["/dashboard"]);
        } else {
          this.router.navigate(["/login/otp"]);
        }
      },
      error: (err) =>
        this.error.set(err?.error?.message ?? "Could not sign in"),
    });
  }
}
```

- [ ] **Step 5: Implement `apps/internal/src/app/login/login.component.html`**

```html
<form [formGroup]="form" (ngSubmit)="submit()">
  <label>
    Username
    <input type="text" autocomplete="username" formControlName="login" />
  </label>
  <label>
    Password
    <input
      type="password"
      autocomplete="current-password"
      formControlName="password"
    />
  </label>

  @if (error()) {
  <p role="alert">{{ error() }}</p>
  }

  <button type="submit" [disabled]="form.invalid">Sign in</button>
</form>
```

- [ ] **Step 6: Run — should pass**

```bash
pnpm nx test internal
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/internal/src/app/login/ apps/internal/project.json apps/internal/vite.config.mts 2>/dev/null
git commit -m "feat(internal): add LoginComponent calling new AuthService"
```

(`apps/internal/vite.config.mts` only added if it didn't exist before Step 1.)

---

## Task 14: Wire `apps/internal/app.config.ts`

Provide the two URL tokens and swap interceptors.

**Files:**

- Modify: `apps/internal/src/app/app.config.ts`

- [ ] **Step 1: Replace `apps/internal/src/app/app.config.ts`**

```ts
import {
  ApplicationConfig,
  provideBrowserGlobalErrorListeners,
  provideZonelessChangeDetection,
} from "@angular/core";
import { provideRouter, withComponentInputBinding } from "@angular/router";
import { provideHttpClient, withInterceptors } from "@angular/common/http";
import { JwtHelperService } from "@auth0/angular-jwt";
import { API_BASE_URL } from "@org/api";
import {
  AUTH_LEGACY_BASE_URL,
  AUTH_SERVICE_BASE_URL,
  errorInterceptor,
  tokenInterceptor,
} from "@org/auth";
import { appRoutes } from "./app.routes";
import { environment } from "../environments/environment";

export const appConfig: ApplicationConfig = {
  providers: [
    provideBrowserGlobalErrorListeners(),
    provideZonelessChangeDetection(),
    provideRouter(appRoutes, withComponentInputBinding()),
    provideHttpClient(withInterceptors([tokenInterceptor, errorInterceptor])),
    JwtHelperService,
    { provide: API_BASE_URL, useValue: environment.apiUrl },
    { provide: AUTH_SERVICE_BASE_URL, useValue: environment.authServiceUrl },
    { provide: AUTH_LEGACY_BASE_URL, useValue: environment.authLegacyUrl },
  ],
};
```

- [ ] **Step 2: Build to confirm wiring compiles**

```bash
pnpm nx build internal --configuration=development
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add apps/internal/src/app/app.config.ts
git commit -m "feat(internal): wire AUTH_SERVICE_BASE_URL, AUTH_LEGACY_BASE_URL, and new interceptors"
```

---

## Task 15: Wire `apps/internal/app.routes.ts`

Replace `LoginComponent` import to local component, add OTP route, add `classificationGuard`.

**Files:**

- Modify: `apps/internal/src/app/app.routes.ts`

- [ ] **Step 1: Replace `apps/internal/src/app/app.routes.ts`**

```ts
import { Route } from "@angular/router";
import { authGuard, classificationGuard, OtpComponent } from "@org/auth";
import { LoginComponent } from "./login/login.component";
import { ShellComponent } from "./shell/shell.component";

export const appRoutes: Route[] = [
  { path: "login", component: LoginComponent },
  {
    path: "login/otp",
    component: OtpComponent,
    data: { classification: "internal", successRedirect: "/dashboard" },
  },
  {
    path: "",
    component: ShellComponent,
    canActivate: [authGuard, classificationGuard(["internal"])],
    children: [
      { path: "", redirectTo: "dashboard", pathMatch: "full" },
      {
        path: "dashboard",
        loadComponent: () =>
          import("./pages/dashboard/dashboard.component").then(
            (m) => m.DashboardComponent,
          ),
      },
      {
        path: "issues",
        loadComponent: () =>
          import("./pages/issues-dashboard/issues-dashboard.component").then(
            (m) => m.IssuesDashboardComponent,
          ),
      },
      {
        path: "referrals/new",
        loadComponent: () =>
          import("@org/referrals").then((m) => m.ReferralWizardShellComponent),
        data: { portal: "internal" },
      },
      {
        path: "referrals/:referenceNumber/edit",
        loadComponent: () =>
          import("@org/referrals").then((m) => m.ReferralEditShellComponent),
        data: { portal: "internal" },
      },
      {
        path: "referrals/:referenceNumber",
        loadComponent: () =>
          import("@org/referrals").then((m) => m.ReferralViewShellComponent),
        data: { portal: "internal" },
      },
      {
        path: "client-view",
        loadComponent: () =>
          import("@org/client-view").then((m) => m.ClientViewListComponent),
      },
      {
        path: "doctor-queue",
        loadComponent: () =>
          import("@org/medical-review").then(
            (m) => m.DoctorQueueShellComponent,
          ),
        data: { portal: "internal" },
      },
      {
        path: "doctor-queue/:id",
        loadComponent: () =>
          import("@org/medical-review").then(
            (m) => m.DoctorReviewDetailShellComponent,
          ),
        data: { portal: "internal" },
      },
      {
        path: "settings",
        loadChildren: () =>
          import("./pages/settings/settings.routes").then(
            (m) => m.SETTINGS_ROUTES,
          ),
      },
    ],
  },
  { path: "**", redirectTo: "" },
];
```

- [ ] **Step 2: Build to confirm**

```bash
pnpm nx build internal --configuration=development
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add apps/internal/src/app/app.routes.ts
git commit -m "feat(internal): route /login to local component and add /login/otp"
```

---

## Task 16: Final verification + manual QA

**Files:** none modified — verification only.

- [ ] **Step 1: Run all tests + lint + build**

```bash
cd /Users/jcshin/dev/cl/carelever_assessment_ui
pnpm nx test auth
pnpm nx test internal
pnpm nx lint auth
pnpm nx lint internal
pnpm nx build internal --configuration=development
```

Expected: all green.

- [ ] **Step 2: Manual QA against the dev backend**

Run the internal app pointed at the dev URLs:

```bash
pnpm nx serve internal --configuration=development
```

In a browser:

1. Navigate to `http://localhost:4200/login`. Should render the login form.
2. Submit valid internal credentials (username@org-slug). Network tab should show `POST https://authentication-api.dev.carelever.com/internal/authenticate`. Response is 2xx with `{ data: { loginAttempt, token } }`.
3. If `loginAttempt = 'otp_required'`: app routes to `/login/otp`. Submit the OTP from email/SMS/authenticator. Network tab should show `POST https://api.dev.carelever.com/authentication/internal/authenticate_otp` carrying header `Authentication: <pre-otp-jwt>`. Response is 2xx with `{ data: <jwt> }`.
4. App lands on `/dashboard`. `localStorage.auth_token` is set; `localStorage.otp_confirmation_token` is cleared.
5. Reload the page. Stays logged in (lands on `/dashboard`).
6. From devtools: `localStorage.removeItem('auth_token')` then navigate to `/dashboard`. Redirected to `/login`.
7. Log in again, then trigger any 401 on an `apiUrl` request (devtools "throttle" or temporarily mutate the token). Confirm redirect to `/login` and both keys cleared.

If any of those fail, report findings and stop — do not declare success.

- [ ] **Step 3: Final commit (if any docs or fixes from manual QA)**

```bash
git status
git add <whatever>
git commit -m "<descriptive message>"
```

If no diffs, skip.

---

## Self-Review Notes

Spec coverage check:

- ✓ Two URL tokens — Tasks 1, 12, 14
- ✓ AuthService surface (signals + login + logout) — Task 2
- ✓ OtpService — Task 3
- ✓ tokenInterceptor — Task 4
- ✓ errorInterceptor — Task 5
- ✓ authGuard rewrite — Task 6
- ✓ classificationGuard — Task 7
- ✓ OtpComponent shared — Task 8
- ✓ MeService stub — Task 9
- ✓ Public exports updated, old surface deleted — Task 10
- ✓ libs/api refactor — Task 11
- ✓ Internal env URLs added — Task 12
- ✓ InternalLoginComponent — Task 13
- ✓ app.config wiring — Task 14
- ✓ app.routes wiring — Task 15
- ✓ Acceptance manual QA — Task 16
- ✓ `@auth0/angular-jwt` dependency — Task 0

Any gaps: none identified.

Type consistency check:

- `Classification` type used in `AuthService.login()`, `OtpService` methods, `classificationGuard` factory, `OtpComponent` route data — consistent.
- `LoginResult.status` discriminator used by both `AuthService.login()` return type and `LoginComponent.submit()` — consistent.
- `AuthService.setToken()` used by `OtpService.authenticateOtp()` — defined in Task 2, consumed in Task 3.
- Storage keys re-exported from `libs/auth` so `apps/internal` doesn't have a stale `AUTH_TOKEN_KEY` import after Task 11.
