/**
 * ConnectionPage.ets — Connection status, GPS, & paired device management
 *
 * Phase 3: per-camera "连接开关" (connection toggle, ON by default = connect +
 * auto-reconnect until switched off) replaces the old connect/disconnect
 * buttons and the global keep-alive toggle. Deleting a camera is a standard
 * HDS swipe-left action (trash icon / swipe-through).
 *
 * MessagesCommonView pattern (requires HdsNavigation ancestor).
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { bundleManager } from '@kit.AbilityKit';
import {
  cameraService, ConnectionState, CameraStateEvent, GpsDeliveryHealth
} from '../service/CameraService';
import { PairedCamera } from '../ble/protocol/NikonPairingEngine';
import { ConnectionPolicy, connectionPolicyDescription, connectionPolicyLabel } from '../service/ConnectionPolicy';
import { HdsNavDestination, ScrollEffectType, hdsMaterial, HdsListItem } from '@kit.UIDesignKit';

const TAG = 'HarmoNiLink-ConnectionPage';

/** Per-camera live state, updated from CameraStateEvent. */
interface CameraStatus {
  name: string;
  state: ConnectionState;
  message: string;
}

@Component
export struct ConnectionPage {
  @State savedCameras: PairedCamera[] = [];
  @State cameraStatuses: CameraStatus[] = [];
  @State logMessages: string[] = [];
  @State showLogs: boolean = false;
  @State appVersion: string = '';
  @State titleSub: string = '';
  @State owner: string = 'none'; // synced from cameraService — drives @State re-render
  @State connectionPolicy: ConnectionPolicy = ConnectionPolicy.Auto;
  // Bumped ONLY when a toggle must visually snap back after a refused flip.
  // Part of the ForEach key: normal list reloads keep keys stable so toggles
  // are NOT recreated (recreation in the same frame as the touch kills the
  // switch animation and can desync the visual from the persisted flag).
  @State revertTick: number = 0;
  private scroller: Scroller = new Scroller();
  private offStateListener: (() => void) | null = null;

  private isPairingOwner(): boolean { return this.owner === 'pairing'; }
  private isConnectionOwner(): boolean { return this.owner === 'connection'; }

  aboutToAppear(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] ConnectionPage aboutToAppear');
    this.loadAppVersion();
    this.loadSavedCameras();
    this.connectionPolicy = cameraService.getConnectionPolicy();
    this.offStateListener = cameraService.setStateListener((event: CameraStateEvent) => {
      // Sync owner first — all derived helpers depend on @State reactivity
      this.owner = cameraService.getOwner();
      if (event.cameraName !== '') {
        this.updateCameraStatus(event.cameraName, event.state, event.message);
      }
      this.logMessages = [...this.logMessages.slice(-49),
        `[${new Date().toLocaleTimeString()}] [${event.cameraName || '全局'}] ${event.state}: ${event.message}`];
      // Title bar subtitle — show progress only for our own operations
      if (this.isPairingOwner()) {
        this.titleSub = '配对页操作中';
      } else if (event.cameraName !== '' && (event.state === ConnectionState.Scanning
        || event.state === ConnectionState.Connecting || event.state === ConnectionState.Discovering
        || event.state === ConnectionState.Pairing || event.state === ConnectionState.Bonding)) {
        this.titleSub = `正在连接 ${event.cameraName}…`;
      } else {
        this.titleSub = '';
      }
      if (event.state === ConnectionState.Ready || event.state === ConnectionState.Idle) {
        this.loadSavedCameras();
      }
    });
    // prefs init is async — the first loadSavedCameras() may see an empty
    // cache. Re-read once it has certainly settled (also triggers reconcile).
    setTimeout(() => { this.loadSavedCameras(); }, 1500);
  }

  aboutToDisappear(): void {
    if (this.offStateListener) { this.offStateListener(); this.offStateListener = null; }
  }

  private updateCameraStatus(name: string, state: ConnectionState, message: string): void {
    const next = this.cameraStatuses.map((c) =>
      c.name === name ? { name, state, message } as CameraStatus : c);
    const found = this.cameraStatuses.some((c) => c.name === name);
    this.cameraStatuses = found ? next : [...this.cameraStatuses, { name, state, message } as CameraStatus];
  }

  private getCameraStatus(name: string): CameraStatus | undefined {
    return this.cameraStatuses.find((c) => c.name === name);
  }

  private relativeTime(timestamp: number): string {
    if (timestamp <= 0) return '--';
    const seconds = Math.max(0, Math.floor((Date.now() - timestamp) / 1000));
    if (seconds < 5) return '刚刚';
    if (seconds < 60) return `${seconds} 秒前`;
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes} 分钟前`;
    return new Date(timestamp).toLocaleTimeString();
  }

  private selectConnectionPolicy(policy: ConnectionPolicy): void {
    cameraService.setConnectionPolicy(policy);
    this.connectionPolicy = policy;
  }

  /**
   * Per-camera connection toggle (Phase 3). ON = connect and keep reconnecting
   * until switched off; OFF = disconnect and stop reconnecting.
   */
  private onConnectToggle(cam: PairedCamera, on: boolean): void {
    if (on) {
      if (this.isPairingOwner()) {
        // Starting a connect needs the radio — pairing owns it exclusively.
        this.getUIContext().getPromptAction().showToast({ message: '配对进行中，请稍后再开启连接', duration: 2000 });
        this.revertToggle();
        return;
      }
      // Already connected/connecting — just persist the intent.
      if (cameraService.isCameraConnected(cam.name) || cameraService.isCameraBusy(cam.name)) {
        cameraService.setKeepAlive(cam.name, true);
        return;
      }
      if (!cameraService.canConnectMore()) {
        this.getUIContext().getPromptAction().showToast({
          message: `已达连接上限（${cameraService.getConnectedCount()} 台），请先关闭其他相机的连接开关`, duration: 2500
        });
        this.revertToggle();
        return;
      }
      // Beyond the field-tested count: warn (dismissable), then connect.
      // "不再提示" persists the dismissal; plain "继续" warns again next time.
      if (cameraService.shouldWarnMultiCam()) {
        this.getUIContext().getPromptAction().showDialog({
          title: '连接更多设备',
          message: '连接更多设备不保证稳定性，且可能增加耗电。',
          buttons: [
            { text: '不再提示', color: $r('app.color.text_secondary') },
            { text: '继续', color: $r('app.color.brand') }
          ]
        }).then((result) => {
          if (result.index === 0) {
            cameraService.markMultiCamWarned();
          }
          this.startPendingConnect(cam);
        }).catch((e: Error) => {
          hilog.warn(0x0001, TAG, `Multi-cam warn dialog err: ${e.message}`);
          this.startPendingConnect(cam); // dialog failed — don't block the user
        });
        return;
      }
      this.startPendingConnect(cam);
    } else {
      // OFF: stop auto-reconnect, then drop the link if one exists.
      cameraService.setKeepAlive(cam.name, false);
      if (cameraService.isCameraConnected(cam.name) || cameraService.isCameraBusy(cam.name)) {
        cameraService.disconnect(cam.name);
      }
    }
  }

  /**
   * Persist the ON intent and run the connect chain: permissions → (one-time
   * first-connect hint dialog) → startReconnect. Every async continuation
   * re-checks the persisted flag so flipping the toggle OFF mid-flight aborts
   * the chain (ghost guard), while a fresh ON never aborts itself.
   */
  private startPendingConnect(cam: PairedCamera): void {
    cameraService.setKeepAlive(cam.name, true);
    // Connecting needs BLE + location permissions — request on demand
    cameraService.requestPermissionsIfNeeded().then((granted: boolean) => {
      // Ghost guard: turned OFF while this chain was in flight — abort.
      if (!cameraService.isKeepAlive(cam.name)) return;
      if (!granted) {
        this.getUIContext().getPromptAction().showToast({ message: '需要蓝牙和位置权限才能连接', duration: 2500 });
        cameraService.setKeepAlive(cam.name, false);
        this.revertToggle();
        return;
      }
      // One-time hint on first connect: camera "关闭时发送" + auto-reconnect
      if (!cameraService.wasConnectHintShown()) {
        cameraService.markConnectHintShown();
        this.getUIContext().getPromptAction().showDialog({
          title: '连接提示',
          message: '为获得稳定连接，推荐：\n\n1. 在相机设置中开启「关闭时发送」——相机休眠/关机后仍保持连接，本 App 可自动重连。\n\n2. 保持设备的连接开关开启——断开后自动持续重连，直到相机恢复。',
          buttons: [{ text: '继续连接', color: $r('app.color.brand') }]
        }).then(() => {
          // Re-check after the dialog too — it can stay up for a long time.
          if (cameraService.isKeepAlive(cam.name)) {
            cameraService.startReconnect(cam);
          }
        }).catch((e: Error) => {
          hilog.warn(0x0001, TAG, `Connect hint dialog err: ${e.message}`);
        });
      } else {
        cameraService.startReconnect(cam);
      }
    });
  }

  /** A toggle was refused — bump the key so it visually snaps back to the
   * persisted flag (the only case where a toggle must be recreated). */
  private revertToggle(): void {
    this.revertTick++;
  }

  /**
   * Keep-alive cameras that are neither connected, connecting, NOR waiting in
   * the reconnect backoff get their connection started (app start / page
   * revisit / after prefs settle). A camera sitting out a backoff window owns
   * its own retry schedule — restarting it here would bypass the backoff and
   * make unrelated events (another camera's cancel, pairing completion) fire
   * connects at random-looking moments.
   */
  private reconcileConnections(): void {
    if (this.isPairingOwner()) return;
    for (const cam of this.savedCameras) {
      if (!cam.keepAlive) continue;
      if (cameraService.isCameraConnected(cam.name) || cameraService.isCameraBusy(cam.name)) continue;
      if (cameraService.isCameraReconnectPending(cam.name)) continue; // backoff owns it
      if (!cameraService.canConnectMore()) break; // cap reached — stop here
      cameraService.startReconnect(cam); // service re-checks cap/owner internally
    }
  }

  private async loadSavedCameras(): Promise<void> {
    try {
      const cams = await cameraService.getSavedCameras();
      this.savedCameras = cams.slice(); // new array ref so ForEach re-diffs
      this.reconcileConnections();
    }
    catch (e) { hilog.warn(0x0001, TAG, `loadSavedCameras err: ${JSON.stringify(e)}`); }
  }

  private loadAppVersion(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.appVersion = `NiLink v${info.versionName}`;
    } catch (e) {
      this.appVersion = '';
    }
  }

  private onForget(cam: PairedCamera): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除已配对设备',
      message: `确定删除「${cam.name}」？\n\n删除后需同时在系统蓝牙设置和相机端清除配对信息，否则可能无法重新连接。`,
      buttons: [
        { text: '取消', color: $r('app.color.brand') },
        { text: '删除', color: $r('app.color.danger') }
      ]
    }).then((result) => {
      if (result.index === 1) {
        // removeCamera() aborts any in-flight connect/pair itself (no ghost
        // connection keeps running after the record is gone).
        cameraService.removeCamera(cam.name).then(() => this.loadSavedCameras())
          .catch((e: Error) => hilog.warn(0x0001, TAG, `Forget err: ${e.message}`));
      }
    }).catch((err: Error) => {
      hilog.warn(0x0001, TAG, `Forget dialog err: ${err.message}`);
    });
  }

  private stateColor(state: ConnectionState): ResourceColor {
    if (state === ConnectionState.Ready) return $r('app.color.success');
    if (state === ConnectionState.Error) return $r('app.color.danger');
    if (state === ConnectionState.Idle) return $r('app.color.text_secondary');
    return $r('app.color.warning');
  }

  private stateLabel(state: ConnectionState): string {
    if (state === ConnectionState.Ready) return '已连接';
    if (state === ConnectionState.Error) return '连接错误';
    if (state === ConnectionState.Idle) return '未连接';
    if (state === ConnectionState.Scanning) return '扫描中';
    if (state === ConnectionState.Connecting) return '连接中';
    if (state === ConnectionState.Discovering) return '发现服务';
    if (state === ConnectionState.Pairing) return '配对中';
    if (state === ConnectionState.Bonding) return '绑定中';
    return state;
  }

  /**
   * Status line under the camera name. While the toggle is ON but the link is
   * down (waiting / auto-reconnecting), show the live message instead of a
   * bare "未连接" — the toggle promises a connection, so say where it is.
   */
  private cameraStateText(cam: PairedCamera): string {
    const status = this.getCameraStatus(cam.name);
    const st = status?.state ?? ConnectionState.Idle;
    if (st === ConnectionState.Idle && cam.keepAlive) {
      const msg = status?.message ?? '';
      return msg !== '' ? msg : '待连接';
    }
    return this.stateLabel(st);
  }

  private cameraHealthText(cam: PairedCamera): string {
    const health: GpsDeliveryHealth = cameraService.getGpsHealth(cam.name);
    if (health.lastGeoWriteAt > 0) return `GPS ${this.relativeTime(health.lastGeoWriteAt)} 已确认`;
    if (health.lastError !== '') return health.lastError;
    if (cameraService.isCameraConnected(cam.name)) return 'GPS 等待确认';
    return 'GPS 未下发';
  }

  @Builder pairingNotice() {
    Column() {
      Row({ space: 8 }) {
        Circle({ width: 8, height: 8 }).fill($r('app.color.warning'))
        Text('配对页正在进行设备配对，连接操作已暂停').fontSize(13).fontColor($r('app.color.warning'))
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(16).backgroundColor($r('app.color.card_background'))
    .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
    .margin({ bottom: 12 })
  }

  @Builder policyOption(policy: ConnectionPolicy, label: string) {
    Column() {
      Text(label).fontSize(12).fontWeight(this.connectionPolicy === policy ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.connectionPolicy === policy ? Color.White : $r('app.color.text_secondary'))
    }
    .layoutWeight(1).height(34).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .borderRadius(6)
    .backgroundColor(this.connectionPolicy === policy ? $r('app.color.brand') : $r('app.color.page_background'))
    .onClick(() => { this.selectConnectionPolicy(policy); })
  }

  @Builder connectionPolicyCard() {
    Column() {
      Text('连接策略').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
      Text(connectionPolicyDescription(this.connectionPolicy)).fontSize(12).fontColor($r('app.color.text_secondary'))
        .width('100%').margin({ top: 4, bottom: 10 })
      Row({ space: 4 }) {
        this.policyOption(ConnectionPolicy.PowerSaving, '省电')
        this.policyOption(ConnectionPolicy.Balanced, '均衡')
        this.policyOption(ConnectionPolicy.Stable, '稳定')
        this.policyOption(ConnectionPolicy.Auto, '自动')
      }.width('100%')
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 14 })
    .borderRadius(16).backgroundColor($r('app.color.card_background'))
    .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
    .margin({ top: 12 })
  }

  @Builder savedDevicesSection() {
    Column() {
      Text('已配对设备').fontSize(14).fontColor($r('app.color.text_secondary'))
        .margin({ left: 12, bottom: 8, top: 28 }).alignSelf(ItemAlign.Start).fontWeight(500)
      if (this.savedCameras.length > 0) {
        // One table card: rows separated by dividers inside a single card
        // (swipe-to-delete is per row via HdsListItem).
        Column() {
          List() {
            ForEach(this.savedCameras, (cam: PairedCamera, i: number) => {
              HdsListItem({
                customItemBuilder: (): void => { this.cameraRow(cam, i < this.savedCameras.length - 1); },
                swipeActionOptions: {
                  deleteIconOptions: {
                    onAction: () => { this.onForget(cam); }
                  },
                  fullDeleteOptions: {
                    isFullDelete: true, // swipe through the card to delete
                    onFullDeleteAction: () => { this.onForget(cam); }
                  }
                }
              })
            }, (cam: PairedCamera) => `${cam.name}_${this.revertTick}`)
          }
          .width('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.None)
        }
        .width('100%').backgroundColor($r('app.color.card_background')).borderRadius(16).padding(4)
        .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
      } else {
        Column() { Text('暂无已配对设备').fontSize(13).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center) }
        .width('100%').height(48).justifyContent(FlexAlign.Center).backgroundColor($r('app.color.card_background')).borderRadius(16)
        .padding({ left: 8, right: 8 })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  /** One table row: name + live state on the left, connection toggle on the
   * right; optional trailing divider separates rows inside the shared card. */
  @Builder cameraRow(cam: PairedCamera, withDivider: boolean) {
    Column() {
      Row() {
        Column() {
          Text(cam.name).fontSize(16).fontWeight(500).fontColor($r('app.color.text_primary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 6 }) {
            Circle({ width: 6, height: 6 }).fill(this.stateColor(this.getCameraStatus(cam.name)?.state ?? ConnectionState.Idle))
            Text(this.cameraStateText(cam))
              .fontSize(11).fontColor(this.stateColor(this.getCameraStatus(cam.name)?.state ?? ConnectionState.Idle))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.margin({ top: 3 })
          Text(this.cameraHealthText(cam))
            .fontSize(10).fontColor($r('app.color.text_secondary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 2 })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: cam.keepAlive })
        // Always interactive: turning OFF is a cancel and must work even
        // while the pairing tab owns the radio (the ON direction refuses
        // with a toast in onConnectToggle instead of a dead switch).
        .onChange((on: boolean) => { this.onConnectToggle(cam, on); })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      if (withDivider) {
        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 12, right: 12 })
      }
    }
  }

  @Builder logSection() {
    Column() {
      Row() {
        Text('日志').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')); Blank()
        Text(this.showLogs ? '收起' : '展开').fontSize(13).fontColor($r('app.color.brand'))
      }.width('100%').onClick(() => { this.showLogs = !this.showLogs; })
      if (this.showLogs) {
        Column() {
          if (this.logMessages.length > 0) {
            ForEach(this.logMessages.slice(-20), (msg: string) => {
              Text(msg).fontSize(10).fontColor($r('app.color.text_secondary')).width('100%').padding({ top: 1, bottom: 1 })
            })
          } else { Text('暂无日志').fontSize(12).fontColor($r('app.color.text_secondary')).padding({ top: 8 }) }
          if (this.appVersion) {
            Text(this.appVersion).fontSize(11).fontColor($r('app.color.text_secondary'))
              .width('100%').textAlign(TextAlign.Center).padding({ top: 8 })
          }
        }.width('100%').margin({ top: 8 })
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 16 })
    .borderRadius(16).backgroundColor($r('app.color.card_background'))
    .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
    .margin({ top: 12 })
  }

  build() {
    HdsNavDestination() {
      Scroll(this.scroller) {
        Column() {
          Blank().height(56)

          if (this.isPairingOwner()) { this.pairingNotice() }
          this.connectionPolicyCard()

          Text('连接开关打开的相机将保持连接，断开后自动重连。\n左滑设备卡片可删除配对。\n需要后台下发数据，请在系统设置中允许始终定位。')
            .fontSize(11).fontColor($r('app.color.text_secondary'))
            .width('100%').textAlign(TextAlign.Center).padding({ left: 4, right: 4 })
            .margin({ top: 12 })
            .lineHeight(16)

          this.savedDevicesSection()
          Text('找不到相机？请前往「配对」页面搜索设备')
            .fontSize(13).fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center).width('100%').padding({ top: 4, bottom: 4 })
            .margin({ top: 12 })
          this.logSection()
          Blank().layoutWeight(1)
        }
        .padding({ left: 16, right: 16, bottom: 56 })
      }
      .height('100%')
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .titleBar({
      content: { title: { mainTitle: '连接', subTitle: this.titleSub || undefined } },
      style: {
        scrollEffectOpts: { scrollEffectType: ScrollEffectType.GRADIENT_BLUR },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        },
      },
    })
    .hideBackButton(true)
  }
}
