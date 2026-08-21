import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { liveViewManager } from '@kit.LiveViewKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HarmoNiLink-LiveView';
const LIVE_VIEW_ID = 26082101;
const MIN_UPDATE_INTERVAL_MS = 3000;

export type LiveViewHealthLevel = 'offline' | 'acquiring' | 'healthy' | 'stale' | 'error';

export interface LiveViewStatus {
  level: LiveViewHealthLevel;
  title: string;
  detail: string;
  readyCameraCount: number;
  lastGeoWriteAt: number;
  locationAccuracy: number;
  policyLabel: string;
}

class LiveViewController {
  private context: common.UIAbilityContext | null = null;
  private active: boolean = false;
  private sequence: number = 0;
  private lastSignature: string = '';
  private lastUpdateAt: number = 0;
  private pendingTimer: number = -1;
  private pendingStatus: LiveViewStatus | null = null;

  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  sync(status: LiveViewStatus, allowStart: boolean): void {
    if (status.level === 'offline') {
      this.stop(status);
      return;
    }

    if (!this.active && !allowStart) return;

    const signature = this.buildSignature(status);
    if (signature === this.lastSignature) return;

    const now = Date.now();
    if (this.active && now - this.lastUpdateAt < MIN_UPDATE_INTERVAL_MS) {
      this.pendingStatus = status;
      if (this.pendingTimer === -1) {
        const delay = MIN_UPDATE_INTERVAL_MS - (now - this.lastUpdateAt);
        this.pendingTimer = setTimeout(() => {
          this.pendingTimer = -1;
          const pending = this.pendingStatus;
          this.pendingStatus = null;
          if (pending) this.sync(pending, allowStart);
        }, delay);
      }
      return;
    }

    this.publish(status, signature);
  }

  stop(status?: LiveViewStatus): void {
    if (this.pendingTimer !== -1) {
      clearTimeout(this.pendingTimer);
      this.pendingTimer = -1;
    }
    this.pendingStatus = null;
    if (!this.active) return;
    this.stopLiveView(status ?? {
      level: 'offline',
      title: '相机已断开',
      detail: 'GPS 下发已停止',
      readyCameraCount: 0,
      lastGeoWriteAt: 0,
      locationAccuracy: -1,
      policyLabel: '--'
    });
  }

  private async publish(status: LiveViewStatus, signature: string): Promise<void> {
    try {
      if (!this.context) return;
      if (!await liveViewManager.isLiveViewEnabled()) return;

      let shouldUpdate = this.active;
      if (!shouldUpdate) {
        shouldUpdate = await this.restoreActiveLiveView();
      }
      const view = await this.buildLiveView(status);
      const operation = shouldUpdate ? 'update' : 'start';
      const result = shouldUpdate
        ? await liveViewManager.updateLiveView(view)
        : await liveViewManager.startLiveView(view);

      this.active = true;
      this.lastSignature = signature;
      this.lastUpdateAt = Date.now();
      hilog.info(0x0001, TAG, `[LIVE] ${operation} result=${result.resultCode}`);
    } catch (err) {
      const e = err as BusinessError;
      if (e.code === 1003500009 || e.code === 1003500010) {
        this.active = false;
        this.lastSignature = '';
        return;
      }
      if (e.code === 1003500006) {
        this.active = true;
        this.lastSignature = '';
        this.sync(status, true);
        return;
      }
      hilog.warn(0x0001, TAG, `[LIVE] publish failed: ${e.code} ${e.message}`);
    }
  }

  private async restoreActiveLiveView(): Promise<boolean> {
    try {
      const activeView = await liveViewManager.getActiveLiveView(LIVE_VIEW_ID);
      this.sequence = Math.max(this.sequence, activeView.sequence ?? 0);
      this.active = true;
      return true;
    } catch (err) {
      return false;
    }
  }

  private async stopLiveView(status: LiveViewStatus): Promise<void> {
    try {
      if (!this.context) return;
      if (!await liveViewManager.isLiveViewEnabled()) return;

      const view = await this.buildLiveView(status);
      const result = await liveViewManager.stopLiveView(view);
      hilog.info(0x0001, TAG, `[LIVE] stop result=${result.resultCode}`);
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(0x0001, TAG, `[LIVE] stop failed: ${e.code} ${e.message}`);
    } finally {
      this.active = false;
      this.sequence = 0;
      this.lastSignature = '';
      this.lastUpdateAt = 0;
    }
  }

  private async buildLiveView(status: LiveViewStatus): Promise<liveViewManager.LiveView> {
    this.sequence++;
    const accent = this.accentColor(status.level);
    const capsuleTitle = this.capsuleTitle(status);
    const capsuleContent = this.capsuleContent(status);
    return {
      id: LIVE_VIEW_ID,
      event: 'NAVIGATION',
      sequence: this.sequence,
      isMute: true,
      liveViewData: {
        primary: {
          title: status.title,
          content: this.content(status, accent),
          keepTime: 1,
          clickAction: await this.buildWantAgent(),
          extensionData: {
            text: this.trim(status.detail, 64),
            type: liveViewManager.ExtensionType.EXTENSION_TYPE_COMMON_TEXT,
            clickAction: await this.buildWantAgent()
          }
        },
        capsule: {
          type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
          status: 1,
          title: capsuleTitle,
          content: capsuleContent,
          backgroundColor: accent
        }
      }
    };
  }

  private async buildWantAgent(): Promise<WantAgent> {
    if (!this.context) {
      throw new Error('LiveView context is empty.');
    }
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: LIVE_VIEW_ID,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return await wantAgent.getWantAgent(wantAgentInfo);
  }

  private content(status: LiveViewStatus, accent: string): liveViewManager.RichText[] {
    const cameraText = status.readyCameraCount > 0 ? `${status.readyCameraCount} 台相机` : '等待相机';
    const accuracyText = status.locationAccuracy >= 0 ? ` · ${Math.round(status.locationAccuracy)} m` : '';
    return [
      { text: cameraText, textColor: accent },
      { text: ` · ${status.policyLabel}${accuracyText}` }
    ];
  }

  private capsuleTitle(status: LiveViewStatus): string {
    if (status.level === 'healthy') return 'GPS 正常';
    if (status.level === 'error') return 'GPS 异常';
    if (status.level === 'stale') return 'GPS 过期';
    return '连接中';
  }

  private capsuleContent(status: LiveViewStatus): string {
    if (status.readyCameraCount > 0) return `${status.readyCameraCount} 台`;
    return status.policyLabel;
  }

  private accentColor(level: LiveViewHealthLevel): string {
    if (level === 'healthy') return '#FF1A7F37';
    if (level === 'error') return '#FFB3261E';
    if (level === 'stale' || level === 'acquiring') return '#FFB26A00';
    return '#FF666666';
  }

  private buildSignature(status: LiveViewStatus): string {
    const accuracy = status.locationAccuracy >= 0 ? Math.round(status.locationAccuracy) : -1;
    const writeBucket = status.lastGeoWriteAt > 0 ? Math.floor(status.lastGeoWriteAt / 5000) : 0;
    return `${status.level}|${status.title}|${status.detail}|${status.readyCameraCount}|${accuracy}|${status.policyLabel}|${writeBucket}`;
  }

  private trim(text: string, max: number): string {
    if (text.length <= max) return text;
    return `${text.substring(0, max - 1)}…`;
  }
}

export const liveViewController = new LiveViewController();
