/**
 * CameraService.ets — Multi-camera connection Hub
 *
 * Phase 1: the Hub now holds MULTIPLE sessions (keyed by camera name) and
 * broadcasts per-session state as events. The single global `_state` mirror
 * from Phase 0 is gone — each CameraSession owns its own state and pushes
 * `CameraStateEvent { cameraName, state, message }` through the Hub.
 *
 * Shared resources stay here: scanner, prefs, pairing engine, satellite
 * subscription, GPS ticker, background task, ownership (tab-level mutex).
 *
 * [CHECKPOINT] Every state transition, handshake step, and error is logged via HiLog.
 * For debugging, use: hdc shell hilog -T HarmoNiLink
 *
 * Based on nsg/android/.../CameraConnectionService.kt
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { geoLocationManager } from '@kit.LocationKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent, abilityAccessCtrl } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PairedCamera, NikonPairingEngine } from '../ble/protocol/NikonPairingEngine';
import { GeoPayloadGenerator, GpsPosition } from '../ble/protocol/GeoPayloadGenerator';
import { TimePayloadGenerator } from '../ble/protocol/TimePayloadGenerator';
import { GpsData } from './GpsData';
import { BleScanner, DiscoveredCamera } from '../ble/BleScanner';
import { PreferencesRepository } from '../data/PreferencesRepository';
import { CameraSession } from './CameraSession';
import { ConnectionPolicy, connectionPolicyLabel } from './ConnectionPolicy';
import { liveViewController, LiveViewStatus } from './LiveViewController';

const TAG = 'HarmoNiLink-CameraService';

// Multi-camera connection cap. 0 = UNLIMITED (default): HarmonyOS has no
// public API for the platform's GATT limit, and field-tested stability only
// covers 2 cameras — the UI warns (dismissable) beyond that instead of
// refusing. Set a positive number to hard-enforce a cap again.
const MAX_CONNECTIONS = 0;

// Connected-camera count considered field-tested; opening connection
// (threshold + 1) triggers the dismissable stability/battery warning.
const MULTI_CAM_WARN_THRESHOLD = 2;

// GPS phase stagger: with N cameras, space each camera's write by this many ms
// so they don't all grab the radio in the same millisecond (Phase 2 power/
// scheduling strategy). 200ms is comfortably below the 1500ms foreground tick.
const GPS_PHASE_STAGGER_MS = 200;

// User-grant permissions needed for scan/pair/connect. Requested in ONE batch
// (system queues the dialogs) on first user action, not at app startup.
const USER_GRANT_PERMISSIONS: string[] = [
  'ohos.permission.ACCESS_BLUETOOTH',
  'ohos.permission.DISCOVER_BLUETOOTH',
  'ohos.permission.APPROXIMATELY_LOCATION',
  'ohos.permission.LOCATION',
];
// Must be requested AFTER LOCATION is granted; failure is non-fatal.
const BACKGROUND_LOCATION_PERMISSION: string = 'ohos.permission.LOCATION_IN_BACKGROUND';

export enum ConnectionState {
  Idle = 'Idle',
  Scanning = 'Scanning',
  Connecting = 'Connecting',
  Discovering = 'Discovering',
  Pairing = 'Pairing',
  Bonding = 'Bonding',
  Ready = 'Ready',
  Error = 'Error',
}

/** A per-camera state change, broadcast to all listeners. */
export interface CameraStateEvent {
  /** '' for global (pairing-scan / ownership) events; otherwise the camera name. */
  cameraName: string;
  state: ConnectionState;
  message: string;
}

export type StateListener = (event: CameraStateEvent) => void;
export type OperationOwner = 'pairing' | 'connection' | 'none';

export type GpsHealthLevel = 'offline' | 'acquiring' | 'healthy' | 'stale' | 'error';

/** Per-camera delivery facts. A phone location fix is not considered delivered
 * until the camera confirms the GEO characteristic write. */
export interface GpsDeliveryHealth {
  cameraName: string;
  lastGeoAttemptAt: number;
  lastGeoWriteAt: number;
  lastErrorAt: number;
  consecutiveFailures: number;
  lastError: string;
}

/** Compact aggregate consumed by the connection page and its persistent island. */
export interface GpsHealthSummary {
  level: GpsHealthLevel;
  title: string;
  detail: string;
  readyCameraCount: number;
  lastGeoWriteAt: number;
  locationAccuracy: number;
  policy: ConnectionPolicy;
}

/** A camera awaiting reconnect on the shared scan (reconnectPool). */
interface ReconnectWatch {
  camera: PairedCamera;
  session: CameraSession;
}

export class CameraService {
  // ==== Public shared state ====

  // Subsystems — SHARED across sessions (exposed to CameraSession).
  scanner: BleScanner = new BleScanner();
  prefs: PreferencesRepository = new PreferencesRepository();
  pairingEngine: NikonPairingEngine = new NikonPairingEngine();

  // GPS shared state — UI reads this directly; the single GPS ticker below
  // fans out to all Ready sessions.
  gpsData: GpsData = new GpsData();
  // Real GNSS satellite count fed by Location Kit's satelliteStatusChange.
  lastSatelliteCount: number = -1;
  // Foreground/background flag — the GPS ticker picks the interval from it.
  isForeground: boolean = true;

  // ==== Private shared state ====

  private stateListeners: StateListener[] = [];
  // Sessions keyed by camera name — multiple in Phase 1.
  private sessions: Map<string, CameraSession> = new Map();
  // Reconnect pool: cameras waiting for their BLE address to be found by ONE
  // shared scan (routed by manufacturerDevice), instead of one scan each.
  private reconnectWatchers: ReconnectWatch[] = [];
  private reconnectScanActive: boolean = false;

  // Ownership — prevents cross-tab operation conflicts (Hub-level mutex).
  private owner: OperationOwner = 'none';

  // Discovered cameras (populated by scanner callback) — shared scan result.
  private discoveredList: DiscoveredCamera[] = [];
  // True while the pairing page's shared scan is active (stop/cancel guard).
  private pairScanActive: boolean = false;

  // Context (set from EntryAbility)
  private abilityContext: common.UIAbilityContext | null = null;

  // Permission state
  private permissionJustGranted: boolean = false;

  // Satellite subscription state — single location source (Hub-owned).
  private satelliteSubscribed: boolean = false;
  private satelliteStatusCb: ((status: geoLocationManager.SatelliteStatusInfo) => void) | null = null;

  // Background task state — one ContinuousTask per app.
  private backgroundTaskStarted: boolean = false;

  // GPS ticker — one interval + alternating TIME/GEO, fanned out to Ready sessions.
  private gpsTimer: number | null = null;
  private gpsStep: number = 0; // 0=TIME, 1=GEO — alternating
  private activeGpsIntervalMs: number = 0;
  private gpsHealthByCamera: Map<string, GpsDeliveryHealth> = new Map();
  private lastSampleLatitude: number | null = null;
  private lastSampleLongitude: number | null = null;
  private lastSampleAt: number = 0;
  private lastMotionMetersPerSecond: number = 0;

  // "保持连接" is a PER-CAMERA flag on PairedCamera (Phase 3). No global
  // toggle state lives here anymore — see isKeepAlive/setKeepAlive below.

  // ==================== Public API ====================

  setStateListener(listener: StateListener): () => void {
    this.stateListeners.push(listener);
    // Return an unregister closure — pages MUST call it on aboutToDisappear,
    // otherwise listeners accumulate on every tab switch (leak + stale @State writes).
    return () => {
      const idx = this.stateListeners.indexOf(listener);
      if (idx !== -1) this.stateListeners.splice(idx, 1);
    };
  }

  getOwner(): OperationOwner { return this.owner; }

  getAbilityContext(): common.UIAbilityContext | null { return this.abilityContext; }

  /** Per-install controller name shown in the camera's paired-device list. */
  getControllerName(): string {
    return this.prefs.getOrCreateControllerName();
  }

  getConnectionPolicy(): ConnectionPolicy {
    return this.prefs.getConnectionPolicySync();
  }

  setConnectionPolicy(policy: ConnectionPolicy): void {
    if (this.getConnectionPolicy() === policy) return;
    this.prefs.saveConnectionPolicy(policy);
    hilog.info(0x0001, TAG, `[GPS] policy=${policy}`);
    this.refreshGpsIntervalIfNeeded();
    this.syncSystemLiveView();
  }

  setContext(ctx: common.UIAbilityContext): void {
    this.abilityContext = ctx;
    liveViewController.setContext(ctx);
    // Satellite subscription is INDEPENDENT of camera connection: the GNSS
    // satellite count is a device-level reading that must NOT reset to "--"
    // when all cameras drop. Subscribe once at startup, keep it alive.
    this.subscribeSatelliteStatus();
    this.prefs.init(ctx).then(() => {
      // A stored policy may differ from the startup default. Reconfigure an
      // already-running ticker as soon as preferences finish loading.
      this.refreshGpsIntervalIfNeeded();
      this.syncSystemLiveView();
    });
  }

  // ==================== 保持连接 (per-camera auto-reconnect, Phase 3) ====================

  /** Keep-alive flag of one paired camera (reads live from the prefs cache). */
  isKeepAlive(name: string): boolean {
    const cam = this.prefs.loadSavedCamerasSync().find((c: PairedCamera) => c.name === name);
    return cam !== undefined && cam.keepAlive;
  }

  /** Flip one camera's connection toggle (SESSION-RUNTIME state — never
   * persisted, so a fresh app launch always starts with every switch OFF);
   * turning it off stops that camera's pending reconnect. */
  setKeepAlive(name: string, on: boolean): void {
    this.prefs.setKeepAliveRuntime(name, on);
    hilog.info(0x0001, TAG, `[RECONNECT] keep-alive ${on ? 'on' : 'off'} for '${name}'`);
    if (!on) {
      const s = this.sessions.get(name);
      if (s) s.onKeepAliveDisabled();
    }
    this.syncSystemLiveView();
  }

  /** True if the first-connect hint (camera "关闭时发送" + keep-alive) has never been shown. */
  wasConnectHintShown(): boolean {
    return this.prefs.wasConnectHintShownSync();
  }

  markConnectHintShown(): void {
    this.prefs.saveConnectHintShown();
  }

  /** True while the user has NOT dismissed the beyond-N-cameras warning. */
  wasMultiCamWarned(): boolean {
    return this.prefs.wasMultiCamWarnedSync();
  }

  markMultiCamWarned(): void {
    this.prefs.saveMultiCamWarned();
  }

  /** Number of cameras whose connection toggle is ON — INTENT, not link
   * state: a camera mid-connect counts too, so rapidly flipping several
   * switches cannot slip past the warning while nothing is Ready yet. */
  getKeepAliveCount(): number {
    return this.prefs.loadSavedCamerasSync().filter((c: PairedCamera) => c.keepAlive).length;
  }

  /** True when opening ANOTHER connection would go beyond the field-tested
   * count — the UI warns (dismissable) before connecting. Based on toggle
   * intent: the in-flight camera's own flag is persisted only inside
   * startPendingConnect(), so the count here is the OTHERS already ON. */
  shouldWarnMultiCam(): boolean {
    return this.getKeepAliveCount() >= MULTI_CAM_WARN_THRESHOLD && !this.wasMultiCamWarned();
  }

  // ==================== Permissions ====================

  async requestPermissionsIfNeeded(): Promise<boolean> {
    this.permissionJustGranted = false;
    const ctx = this.abilityContext;
    if (!ctx) return false;
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const tokenId = ctx.applicationInfo.accessTokenId;
      const check = atManager.checkAccessTokenSync as Function;

      const needed: string[] = [];
      for (let i = 0; i < USER_GRANT_PERMISSIONS.length; i++) {
        const permission = USER_GRANT_PERMISSIONS[i];
        if (check(tokenId, permission) !== 0) needed.push(permission);
      }
      if (needed.length === 0) return true;

      hilog.info(0x0001, TAG, `[PERM] requesting ${needed.length} permission(s): ${needed.join(', ')}`);
      const req = atManager.requestPermissionsFromUser as Function;
      const result = await req(ctx, needed) as Record<string, Object>;
      const authResults = result['authResults'] as number[];

      let allGranted: boolean = true;
      for (let i = 0; i < authResults.length; i++) {
        if (authResults[i] !== 0) allGranted = false;
      }
      hilog.info(0x0001, TAG, `[PERM] batch result: ${authResults.join(', ')} allGranted=${allGranted}`);

      this.permissionJustGranted = allGranted;
      return allGranted;
    } catch (err) {
      hilog.warn(0x0001, TAG, `[PERM] request failed: ${JSON.stringify(err)}`);
      return false;
    }
  }

  wasPermissionJustGranted(): boolean {
    return this.permissionJustGranted;
  }

  isBackgroundLocationGranted(): boolean {
    const ctx = this.abilityContext;
    if (!ctx) return false;
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const check = atManager.checkAccessTokenSync as Function;
      return check(ctx.applicationInfo.accessTokenId, BACKGROUND_LOCATION_PERMISSION) === 0;
    } catch (err) {
      hilog.warn(0x0001, TAG, `[PERM] background check error: ${JSON.stringify(err)}`);
      return false;
    }
  }

  openBackgroundLocationSetting(): void {
    const ctx = this.abilityContext;
    if (!ctx) return;
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const req = atManager.requestPermissionOnSetting as Function;
      req(ctx, [BACKGROUND_LOCATION_PERMISSION]).then((statuses: number[]) => {
        hilog.info(0x0001, TAG, `[PERM] on-setting result: ${statuses.join(', ')}`);
      }).catch((err: BusinessError) => {
        hilog.warn(0x0001, TAG, `[PERM] requestPermissionOnSetting failed: ${err.message}`);
      });
    } catch (err) {
      hilog.warn(0x0001, TAG, `[PERM] requestPermissionOnSetting exception: ${JSON.stringify(err)}`);
    }
  }

  // ==================== Ownership (Hub-level mutex) ====================

  requestOwnership(source: OperationOwner): boolean {
    if (this.owner === 'none') { this.owner = source; return true; }
    if (this.owner === source) { return true; } // already owned by same caller
    hilog.warn(0x0001, TAG, `[OWNER] request denied: ${source} (active: ${this.owner})`);
    return false;
  }

  releaseOwnership(): void {
    hilog.info(0x0001, TAG, `[OWNER] released: ${this.owner}`);
    this.owner = 'none';
    // Re-broadcast a global event so listeners refresh their ownership mirror.
    // The caller's setState usually fires BEFORE this (while owner is still the
    // old value) — without this the UI stays stuck thinking it still owns the tab.
    this.broadcastSessionState('', ConnectionState.Idle, '');
  }

  /**
   * True while the pairing tab holds the global radio mutex. This is the ONLY
   * real mutex: connection/reconnect operations may run on many sessions in
   * parallel, so they never take ownership — they only defer to pairing
   * (classic bonding needs the radio exclusively). The old 'connection' owner
   * could not express "two sessions connecting at once" and let an early
   * Ready release stragglers' fallbacks (P0-1).
   */
  isPairingActive(): boolean {
    return this.owner === 'pairing';
  }

  // ==================== Scan (Pairing Page, shared) ====================

  startPairingScan(): boolean {
    if (!this.requestOwnership('pairing')) return false;
    hilog.info(0x0001, TAG, '[CHECKPOINT] startPairingScan() called');
    this.discoveredList = [];
    this.pairScanActive = true;
    this.broadcastSessionState('', ConnectionState.Scanning, '正在扫描设备…');
    this.scanner.startScan((cameras: DiscoveredCamera[]) => {
      this.discoveredList = cameras;
    }, false); // NO classic discovery — it starves connected cameras' GPS writes (P1-5);
    // classic discovery only runs later, inside the short bonding window
    return true;
  }

  getDiscoveredCameras(): DiscoveredCamera[] {
    return this.discoveredList;
  }

  /**
   * Stop the pairing tab's scan WITHOUT killing the shared reconnect scan:
   * if reconnect watchers still exist, the underlying BLE scan must keep
   * running for them (sessions must never call scanner.stopScan() directly —
   * that offs every listener, P0-2).
   */
  stopPairingScanOnly(): void {
    if (!this.pairScanActive) return;
    this.pairScanActive = false;
    if (this.reconnectWatchers.length === 0) {
      this.scanner.stopScan(); // nobody else needs the scan
    }
    // else: shared reconnect scan keeps running for the remaining watchers
  }

  stopPairingScan(): void {
    if (!this.pairScanActive) return; // handshake already in flight — mutex stays with pairing
    this.stopPairingScanOnly();
    if (this.owner === 'pairing') {
      this.releaseOwnership();
      this.broadcastSessionState('', ConnectionState.Idle, '扫描已停止');
    }
  }

  // ==================== Delegated per-camera operations ====================

  /** Pairing progress of the in-flight pairing session (pairing is serial). */
  getPairingStep(): number {
    let step = 0;
    this.sessions.forEach((s: CameraSession) => {
      const ps = s.getPairingStep();
      if (ps > step) step = ps;
    });
    return step;
  }

  /** True if a session for this camera exists and is connected. */
  isCameraConnected(name: string): boolean {
    const s = this.sessions.get(name);
    return s !== undefined && s.isConnected();
  }

  /** True while this camera is connecting/pairing/reconnecting (not Idle). */
  isCameraBusy(name: string): boolean {
    const s = this.sessions.get(name);
    return s !== undefined && s.getState() !== ConnectionState.Idle;
  }

  /** True if this camera has a pending auto-reconnect backoff timer. The
   * timer (not an external reconcile) owns when its next attempt fires. */
  isCameraReconnectPending(name: string): boolean {
    const s = this.sessions.get(name);
    return s !== undefined && s.isReconnectScheduled();
  }

  /** Number of currently Ready (connected) cameras. */
  getConnectedCount(): number {
    return this.getReadySessions().length;
  }

  /** True if another camera can still be connected under the cap (0 = uncapped). */
  canConnectMore(): boolean {
    return MAX_CONNECTIONS <= 0 || this.getConnectedCount() < MAX_CONNECTIONS;
  }

  startReconnect(camera: PairedCamera): boolean {
    if (!this.canConnectMore()) {
      hilog.warn(0x0001, TAG,
        `[CONN] limit reached (${this.getConnectedCount()}/${MAX_CONNECTIONS}) — refused ${camera.name}`);
      return false;
    }
    return this.getOrCreateSession(camera.name).startReconnect(camera);
  }

  /** Disconnect a specific camera, or (no arg) all connected cameras. */
  disconnect(name?: string): void {
    if (name) {
      const s = this.sessions.get(name);
      if (s) s.disconnect();
      return;
    }
    this.sessions.forEach((s: CameraSession) => {
      if (s.isConnected()) s.disconnect();
    });
  }

  cancelPairing(): void {
    this.sessions.forEach((s: CameraSession) => {
      const st = s.getState();
      if (st === ConnectionState.Connecting || st === ConnectionState.Discovering
        || st === ConnectionState.Pairing || st === ConnectionState.Bonding) {
        s.cancelPairing();
      }
    });
  }

  selectDiscoveredCamera(camera: DiscoveredCamera): void {
    this.getOrCreateSession(camera.deviceName).selectDiscoveredCamera(camera);
  }

  // ==================== GPS (single ticker, fan-out to Ready sessions) ====================

  /**
   * Reconcile the GPS ticker with the current Ready sessions: restart (fan out
   * to the remaining cameras) if any remain, else stop. Call after ONE camera
   * disconnects/links-out — a bare stopGpsLoop() would kill GPS for the OTHER
   * still-connected cameras.
   */
  refreshGps(): void {
    if (this.getReadySessions().length > 0) {
      // A Ready camera exists: keep the ticker running, but DON'T restart it.
      // Restarting resets the satellite count (stopGpsLoop sets it to -1) and
      // re-subscribes; getReadySessions() is dynamic, so the running ticker
      // already fans out to the changed set on its next beat.
      this.ensureGpsRunning();
    } else {
      this.stopGpsLoop();
      this.stopBackgroundTask();
    }
    this.syncSystemLiveView();
  }

  /** Start the ticker only if it isn't already running, or reconfigure it when
   * a policy/location change selects a different cadence. */
  private ensureGpsRunning(): void {
    if (this.gpsTimer !== null) {
      this.refreshGpsIntervalIfNeeded();
      return;
    }
    this.startGpsLoop();
  }

  startGpsLoop(): void {
    const interval = this.getGpsIntervalMs();
    hilog.info(0x0001, TAG,
      `[GPS] startGpsLoop: policy=${this.getConnectionPolicy()} interval=${interval}ms fg=${this.isForeground}`);
    this.stopGpsLoop();
    // Idempotent retry: setContext() subscribes at startup, but location
    // permission may not be granted yet then (it's requested on first scan).
    // Re-attempt here (no-op if already subscribed).
    this.subscribeSatelliteStatus();
    this.gpsStep = 0;
    // Send TIME immediately, then alternate TIME/GEO
    this.sendGpsTick();
    this.gpsTimer = setInterval(() => { this.sendGpsTick(); }, interval);
    this.activeGpsIntervalMs = interval;
    this.startBackgroundTask();
  }

  private refreshGpsIntervalIfNeeded(): void {
    if (this.gpsTimer === null) return;
    const nextInterval = this.getGpsIntervalMs();
    if (nextInterval === this.activeGpsIntervalMs) return;
    clearInterval(this.gpsTimer);
    this.gpsTimer = setInterval(() => { this.sendGpsTick(); }, nextInterval);
    this.activeGpsIntervalMs = nextInterval;
    hilog.info(0x0001, TAG,
      `[GPS] cadence adjusted: policy=${this.getConnectionPolicy()} interval=${nextInterval}ms`);
  }

  private getGpsIntervalMs(): number {
    const foreground = this.isForeground;
    const policy = this.getConnectionPolicy();
    if (policy === ConnectionPolicy.Stable) return foreground ? 1500 : 5000;
    if (policy === ConnectionPolicy.Balanced) return foreground ? 5000 : 15000;
    if (policy === ConnectionPolicy.PowerSaving) return foreground ? 15000 : 30000;

    // Auto: recover quickly from weak delivery, follow fast movement, then
    // settle into a low-power cadence when the phone remains still.
    if (!this.gpsData.hasFix || this.hasRecentGpsFailure()) return foreground ? 3000 : 8000;
    if (this.lastMotionMetersPerSecond >= 8) return foreground ? 2500 : 8000;
    if (this.lastMotionMetersPerSecond >= 1.5) return foreground ? 5000 : 15000;
    return foreground ? 15000 : 30000;
  }

  private hasRecentGpsFailure(): boolean {
    const now = Date.now();
    let failed = false;
    this.gpsHealthByCamera.forEach((health: GpsDeliveryHealth) => {
      if (health.lastErrorAt > health.lastGeoWriteAt && now - health.lastErrorAt < 60000) {
        failed = true;
      }
    });
    return failed;
  }

  /** Ready sessions — only those whose handshake finished (chars prepared).
   *  isConnected() alone is true mid-pairing (gattClient exists but TIME/GEO
   *  chars aren't ready), and fanning GPS writes into such a session crashes
   *  writeCharacteristicValue with a 401. */
  private getReadySessions(): CameraSession[] {
    const ready: CameraSession[] = [];
    this.sessions.forEach((s: CameraSession) => {
      if (s.getState() === ConnectionState.Ready) ready.push(s);
    });
    return ready;
  }

  private sendGpsTick(): void {
    const ready = this.getReadySessions();
    if (ready.length === 0) {
      this.stopGpsLoop();
      return;
    }
    if (this.gpsStep === 0) {
      const timePayload = TimePayloadGenerator.build();
      hilog.info(0x0001, TAG, `[GPS] TIME ${timePayload.length}B to ${ready.length} camera(s)`);
      for (let i = 0; i < ready.length; i++) {
        this.staggeredWrite(ready[i], i, timePayload, true);
      }
      this.gpsStep = 1;
    } else {
      this.gpsStep = 0;
      // Check if location service is enabled
      try {
        const locEnabled = geoLocationManager.isLocationEnabled?.() ?? true;
        if (!locEnabled) {
          hilog.warn(0x0001, TAG, '[GPS] Location service disabled, skip GEO');
          this.recordLocationFailure('系统定位服务未开启');
          return;
        }
      } catch (e) { /* proceed anyway */ }

      try {
        geoLocationManager.getCurrentLocation({
          priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
          timeoutMs: 5000
        }).then((pos) => {
          const stillReady = this.getReadySessions();
          if (stillReady.length === 0) return;
          // Update shared GPS state
          const lat = pos.latitude;
          const lon = pos.longitude;
          const alt = Math.round(pos.altitude);
          const accuracy = pos.accuracy;
          const sats = this.lastSatelliteCount;
          const now = Date.now();
          this.gpsData.hasFix = true;
          this.gpsData.latitude = lat;
          this.gpsData.longitude = lon;
          this.gpsData.altitude = alt;
          this.gpsData.satellites = sats;
          this.gpsData.lastUpdateTime = new Date().toLocaleTimeString();
          this.gpsData.lastLocationAt = now;
          this.gpsData.lastLocationAccuracy = accuracy;
          this.gpsData.lastLocationError = '';
          this.updateMotionEstimate(lat, lon, now);

          const gps: GpsPosition = {
            latitude: lat, longitude: lon, altitude: alt,
            satellites: sats >= 0 ? sats : 6, timestamp: new Date()
          };
          hilog.info(0x0001, TAG, `[GPS] GEO real lat=${lat.toFixed(6)} lon=${lon.toFixed(6)}`);
          const payload = GeoPayloadGenerator.buildReal(gps);
          for (let i = 0; i < stillReady.length; i++) {
            this.staggeredWrite(stillReady[i], i, payload, false);
          }
          this.refreshGpsIntervalIfNeeded();
        }).catch(() => {
          hilog.debug(0x0001, TAG, '[GPS] GEO skip — no location');
          this.recordLocationFailure('未能获取定位');
        });
      } catch (e) {
        hilog.debug(0x0001, TAG, '[GPS] GEO skip — exception');
        this.recordLocationFailure('定位服务异常');
      }
    }
  }

  /**
   * Fan a write out to one camera, staggered by its index so N cameras don't
   * all transmit in the same instant. Writes are self-guarding (BleClient
   * drops them if the link is gone), so a delayed write after a disconnect is
   * harmless.
   */
  private staggeredWrite(session: CameraSession, index: number, payload: Uint8Array, isTime: boolean): void {
    const delay = index * GPS_PHASE_STAGGER_MS;
    const doWrite = (): void => {
      if (isTime) {
        session.writeTime(payload);
      } else {
        this.recordGeoWriteAttempt(session.getCameraName());
        session.writeGeo(payload);
      }
    };
    if (delay === 0) {
      doWrite();
    } else {
      setTimeout(doWrite, delay);
    }
  }

  stopGpsLoop(): void {
    if (this.gpsTimer !== null) {
      clearInterval(this.gpsTimer);
      this.gpsTimer = null;
      this.activeGpsIntervalMs = 0;
      hilog.info(0x0001, TAG, '[CHECKPOINT] GPS loop stopped');
    }
    // Satellite subscription is independent of the ticker — do NOT reset
    // lastSatelliteCount here, so the satellite count survives camera drops.
  }

  private subscribeSatelliteStatus(): void {
    if (this.satelliteSubscribed) return;
    try {
      this.satelliteStatusCb = (status: geoLocationManager.SatelliteStatusInfo) => {
        if (status.satellitesNumber >= 0) {
          this.lastSatelliteCount = status.satellitesNumber;
        }
      };
      geoLocationManager.on('satelliteStatusChange', this.satelliteStatusCb);
      this.satelliteSubscribed = true;
      hilog.info(0x0001, TAG, '[GPS] subscribed to satelliteStatusChange');
    } catch (err) {
      this.satelliteSubscribed = false;
      this.satelliteStatusCb = null;
      hilog.warn(0x0001, TAG, `[GPS] satelliteStatusChange subscribe failed: ${JSON.stringify(err)}`);
    }
  }

  // ==================== GPS Delivery Health ====================

  getGpsHealth(cameraName: string): GpsDeliveryHealth {
    const health = this.gpsHealthByCamera.get(cameraName);
    if (health) return { ...health };
    return this.newGpsHealth(cameraName);
  }

  getGpsHealthSummary(): GpsHealthSummary {
    const policy = this.getConnectionPolicy();
    const ready = this.getReadySessions();
    const active = this.getActiveSessionCount();
    if (ready.length === 0) {
      const recentFailure = this.getLatestGpsFailure();
      if (recentFailure && (active > 0 || this.getKeepAliveCount() > 0)
        && Date.now() - recentFailure.lastErrorAt < 60000) {
        return this.healthSummary('error', 'GPS 传输异常',
          `${recentFailure.lastError}，正在等待重连。`, 0, recentFailure.lastGeoWriteAt, policy);
      }
      if (this.owner === 'pairing') {
        return this.healthSummary('acquiring', '正在配对', '配对完成后将开始 GPS 下发。', 0, 0, policy);
      }
      if (active > 0 || this.getKeepAliveCount() > 0) {
        return this.healthSummary('acquiring', '正在连接', '等待相机完成连接与服务发现。', 0, 0, policy);
      }
      return this.healthSummary('offline', '未连接相机', '打开相机连接开关后开始监控 GPS 传输。', 0, 0, policy);
    }

    if (!this.gpsData.hasFix || this.gpsData.lastLocationAt === 0) {
      const detail = this.gpsData.lastLocationError !== ''
        ? this.gpsData.lastLocationError
        : '已连接相机，等待手机提供有效位置。';
      return this.healthSummary('acquiring', '正在获取定位', detail, ready.length, 0, policy);
    }

    let newestWrite = 0;
    let unconfirmedCamera: GpsDeliveryHealth | null = null;
    let failedCamera: GpsDeliveryHealth | null = null;
    for (let i = 0; i < ready.length; i++) {
      const health = this.getGpsHealth(ready[i].getCameraName());
      newestWrite = Math.max(newestWrite, health.lastGeoWriteAt);
      if (health.lastGeoWriteAt === 0) unconfirmedCamera = health;
      if (health.lastErrorAt > health.lastGeoWriteAt) failedCamera = health;
    }

    if (failedCamera) {
      return this.healthSummary('error', 'GPS 传输异常',
        `${failedCamera.cameraName}：${failedCamera.lastError}`, ready.length, newestWrite, policy);
    }

    if (unconfirmedCamera || newestWrite === 0) {
      const detail = unconfirmedCamera
        ? `${unconfirmedCamera.cameraName} 等待确认 GEO 写入。`
        : '已获取位置，等待相机确认 GEO 写入。';
      return this.healthSummary('acquiring', '等待相机确认', detail, ready.length, newestWrite, policy);
    }

    const now = Date.now();
    const stale = now - newestWrite > this.getGpsStaleAfterMs();
    if (stale) {
      return this.healthSummary('stale', 'GPS 确认已过期',
        `相机最后确认于 ${this.relativeTime(newestWrite)}。`,
        ready.length, newestWrite, policy);
    }

    return this.healthSummary('healthy', 'GPS 正在下发',
      `${ready.length} 台相机已确认，最近一次 ${this.relativeTime(newestWrite)}。`,
      ready.length, newestWrite, policy);
  }

  recordGeoWriteSuccess(cameraName: string): void {
    if (cameraName === '') return;
    const health = this.ensureGpsHealth(cameraName);
    health.lastGeoWriteAt = Date.now();
    health.consecutiveFailures = 0;
    health.lastError = '';
    hilog.debug(0x0001, TAG, `[GPS] GEO confirmed by '${cameraName}'`);
    this.refreshGpsIntervalIfNeeded();
    this.syncSystemLiveView();
  }

  recordGeoWriteFailure(cameraName: string, reason: string): void {
    if (cameraName === '') return;
    const health = this.ensureGpsHealth(cameraName);
    health.lastErrorAt = Date.now();
    health.consecutiveFailures++;
    health.lastError = reason;
    hilog.warn(0x0001, TAG,
      `[GPS] GEO delivery failure for '${cameraName}': ${reason} (${health.consecutiveFailures})`);
    this.refreshGpsIntervalIfNeeded();
    this.syncSystemLiveView();
  }

  private recordGeoWriteAttempt(cameraName: string): void {
    if (cameraName === '') return;
    this.ensureGpsHealth(cameraName).lastGeoAttemptAt = Date.now();
  }

  private recordLocationFailure(reason: string): void {
    this.gpsData.hasFix = false;
    this.gpsData.lastLocationError = reason;
    this.refreshGpsIntervalIfNeeded();
    this.syncSystemLiveView();
  }

  private getLatestGpsFailure(): GpsDeliveryHealth | null {
    let latest: GpsDeliveryHealth | null = null;
    this.gpsHealthByCamera.forEach((health: GpsDeliveryHealth) => {
      if (health.lastError === '') return;
      if (latest === null || health.lastErrorAt > latest.lastErrorAt) latest = health;
    });
    return latest;
  }

  private ensureGpsHealth(cameraName: string): GpsDeliveryHealth {
    const existing = this.gpsHealthByCamera.get(cameraName);
    if (existing) return existing;
    const health = this.newGpsHealth(cameraName);
    this.gpsHealthByCamera.set(cameraName, health);
    return health;
  }

  private newGpsHealth(cameraName: string): GpsDeliveryHealth {
    return {
      cameraName: cameraName,
      lastGeoAttemptAt: 0,
      lastGeoWriteAt: 0,
      lastErrorAt: 0,
      consecutiveFailures: 0,
      lastError: '',
    };
  }

  private getActiveSessionCount(): number {
    let count = 0;
    this.sessions.forEach((session: CameraSession) => {
      if (session.getState() !== ConnectionState.Idle) count++;
    });
    return count;
  }

  private healthSummary(
    level: GpsHealthLevel,
    title: string,
    detail: string,
    readyCameraCount: number,
    lastGeoWriteAt: number,
    policy: ConnectionPolicy
  ): GpsHealthSummary {
    return {
      level: level,
      title: title,
      detail: detail,
      readyCameraCount: readyCameraCount,
      lastGeoWriteAt: lastGeoWriteAt,
      locationAccuracy: this.gpsData.lastLocationAccuracy,
      policy: policy,
    };
  }

  private getGpsStaleAfterMs(): number {
    return Math.max(this.getGpsIntervalMs() * 3, 15000);
  }

  private relativeTime(timestamp: number): string {
    const seconds = Math.max(0, Math.floor((Date.now() - timestamp) / 1000));
    if (seconds < 5) return '刚刚';
    if (seconds < 60) return `${seconds} 秒前`;
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes} 分钟前`;
    return new Date(timestamp).toLocaleTimeString();
  }

  private updateMotionEstimate(latitude: number, longitude: number, timestamp: number): void {
    if (this.lastSampleLatitude !== null && this.lastSampleLongitude !== null && this.lastSampleAt > 0) {
      const distance = this.distanceMeters(this.lastSampleLatitude, this.lastSampleLongitude, latitude, longitude);
      const seconds = Math.max(1, (timestamp - this.lastSampleAt) / 1000);
      this.lastMotionMetersPerSecond = Math.min(60, distance / seconds);
    }
    this.lastSampleLatitude = latitude;
    this.lastSampleLongitude = longitude;
    this.lastSampleAt = timestamp;
  }

  private distanceMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
    const earthRadius = 6371000;
    const toRadians = (degree: number): number => degree * Math.PI / 180;
    const dLat = toRadians(lat2 - lat1);
    const dLon = toRadians(lon2 - lon1);
    const a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
      + Math.cos(toRadians(lat1)) * Math.cos(toRadians(lat2))
      * Math.sin(dLon / 2) * Math.sin(dLon / 2);
    return earthRadius * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  }

  // ==================== Persistence ====================

  async getSavedCameras(): Promise<PairedCamera[]> {
    return this.prefs.loadSavedCamerasSync();
  }

  /** Synchronous already-paired check — the pairing page disables the 配对
   *  button for these (re-pairing must go through remove + fresh scan). */
  isPairedCamera(name: string): boolean {
    return this.prefs.loadSavedCamerasSync().some((c: PairedCamera) => c.name === name);
  }

  async removeCamera(name: string): Promise<void> {
    // Remove the record FIRST, then abort the session: disconnect() broadcasts
    // an Idle event synchronously, and ConnectionPage's reconcile would see the
    // still-saved record + an Idle session and immediately RESTART the connect
    // the user just asked to delete (ghost reconnect race).
    await this.prefs.removeCamera(name);
    const s = this.sessions.get(name);
    if (s) {
      s.cancelReconnectTimer();
      // Kills the in-flight connect/pair (watchdog + owner + shared-scan watch
      // + GATT link) and sets Idle so the stale guard swallows any late BLE
      // callbacks — including a connect that succeeds after the delete.
      s.disconnect();
    }
    // Drop the session entirely: a re-pair of the same camera must start from
    // a fresh session, not inherit this one's leftovers.
    this.sessions.delete(name);
    this.gpsHealthByCamera.delete(name);
    this.refreshGps();
  }

  // ==================== Lifecycle (App Background/Foreground) ====================

  onAppBackground(): void {
    hilog.info(0x0001, TAG, '[LIFECYCLE] App → Background');
    this.isForeground = false;
    if (this.getReadySessions().length > 0) {
      this.refreshGpsIntervalIfNeeded();
    }
    this.syncSystemLiveView();
  }

  onAppForeground(): void {
    hilog.info(0x0001, TAG, '[LIFECYCLE] App → Foreground');
    this.isForeground = true;
    if (this.getReadySessions().length > 0) {
      this.refreshGpsIntervalIfNeeded();
    }
    this.syncSystemLiveView();
  }

  // ==================== Background Task ====================

  private async startBackgroundTask(): Promise<void> {
    if (this.backgroundTaskStarted || !this.abilityContext) return;

    const ctx = this.abilityContext;

    let wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: ctx.abilityInfo.bundleName,
          abilityName: ctx.abilityInfo.name
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };

    try {
      const agent: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      try {
        await backgroundTaskManager.startBackgroundRunning(ctx,
          backgroundTaskManager.BackgroundMode.BLUETOOTH_INTERACTION |
          backgroundTaskManager.BackgroundMode.LOCATION, agent);
        this.backgroundTaskStarted = true;
        hilog.info(0x0001, TAG, '[BG] ContinuousTask started (BLUETOOTH + LOCATION)');
      } catch (err) {
        hilog.warn(0x0001, TAG,
          `[BG] startBackgroundRunning fail: ${(err as BusinessError).code} ${(err as BusinessError).message}`);
      }
    } catch (err) {
      hilog.warn(0x0001, TAG,
        `[BG] getWantAgent fail: ${(err as BusinessError).code} ${(err as BusinessError).message}`);
    }
  }

  stopBackgroundTask(): void {
    if (!this.backgroundTaskStarted || !this.abilityContext) return;

    try {
      backgroundTaskManager.stopBackgroundRunning(this.abilityContext);
      this.backgroundTaskStarted = false;
      hilog.info(0x0001, TAG, '[BG] ContinuousTask stopped');
    } catch (err) {
      hilog.warn(0x0001, TAG,
        `[BG] stopBackgroundRunning error: ${(err as BusinessError).code} ${(err as BusinessError).message}`);
    }
  }

  stopSystemLiveView(): void {
    liveViewController.stop(this.toLiveViewStatus());
  }

  // ==================== State broadcast ====================

  /** Broadcast a per-camera (or global, name='') state change to all listeners. */
  broadcastSessionState(cameraName: string, state: ConnectionState, message: string): void {
    hilog.info(0x0001, TAG, `[CHECKPOINT] STATE: [${cameraName || '(global)'}] ${state} — ${message}`);
    for (let i = 0; i < this.stateListeners.length; i++) {
      this.stateListeners[i]({ cameraName, state, message });
    }
    this.syncSystemLiveView();
  }

  // ==================== Reconnect pool (shared scan) ====================

  /**
   * Register a camera waiting to be reconnected. One shared scan serves all
   * watchers (routed by manufacturerDevice), so N sleeping cameras open one
   * scan instead of N — and their callbacks can't overwrite each other.
   */
  watchReconnect(camera: PairedCamera, session: CameraSession): void {
    this.unwatchReconnect(camera.name); // dedupe by name
    this.reconnectWatchers.push({ camera, session });
    if (!this.reconnectScanActive) {
      this.reconnectScanActive = true;
      this.scanner.startScan((cameras: DiscoveredCamera[]) => {
        this.routeReconnect(cameras);
      }, false); // reconnect scan — never classic discovery (it starves GPS writes)
    }
  }

  unwatchReconnect(name: string): void {
    this.reconnectWatchers = this.reconnectWatchers.filter((w) => w.camera.name !== name);
    if (this.reconnectWatchers.length === 0 && this.reconnectScanActive) {
      this.reconnectScanActive = false;
      // The pairing tab's scan may be riding the same underlying scan —
      // only stop the hardware scan when nobody needs it anymore.
      if (!this.pairScanActive) this.scanner.stopScan();
    }
  }

  /** Shared-scan callback: match each watcher by device ID (name fallback). */
  private routeReconnect(cameras: DiscoveredCamera[]): void {
    const matched: ReconnectWatch[] = [];
    for (const w of this.reconnectWatchers) {
      const devHit = cameras.find((c) =>
        c.manufacturerDevice !== undefined
          && (c.manufacturerDevice >>> 0) === (w.camera.device >>> 0));
      const found = devHit ?? cameras.find((c) => c.deviceName === w.camera.name);
      if (found) {
        matched.push(w);
        w.session.onReconnectFound(found, w.camera, devHit !== undefined);
      }
    }
    for (const m of matched) {
      this.unwatchReconnect(m.camera.name);
    }
  }

  // ==================== Session management ====================

  private getOrCreateSession(name: string): CameraSession {
    let s = this.sessions.get(name);
    if (!s) {
      s = new CameraSession(this);
      this.sessions.set(name, s);
    }
    return s;
  }

  private syncSystemLiveView(): void {
    liveViewController.sync(this.toLiveViewStatus(), this.isForeground);
  }

  private toLiveViewStatus(): LiveViewStatus {
    const summary = this.getGpsHealthSummary();
    return {
      level: summary.level,
      title: summary.title,
      detail: summary.detail,
      readyCameraCount: summary.readyCameraCount,
      lastGeoWriteAt: summary.lastGeoWriteAt,
      locationAccuracy: summary.locationAccuracy,
      policyLabel: connectionPolicyLabel(summary.policy)
    };
  }
}

// Global singleton — shared across all pages
export const cameraService = new CameraService();
