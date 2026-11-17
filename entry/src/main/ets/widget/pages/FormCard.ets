/**
 * 鸿蒙互动卡片：桌面 2x2 播放控制卡片。
 * 显示当前曲目名 + 当前歌词行，底部三个控制键（上一首/播放暂停/下一首）。
 *
 * 控制键用 postCardAction 的 call 动作：卡片进程碰不到播放器（独立进程），
 * call 会把命令送进主应用进程的 EntryAbility.onNewWant，在那里直接驱动 PlayerCore，
 * 应用可以完全在后台响应，不闪界面。
 * 整卡点击仍是 router 拉起播放页。
 */
import { APP_FONT, APP_FONT_BOLD } from '../../utils/Fonts';

let storage = new LocalStorage();

@Entry(storage)
@Component
struct FormCard {
  @LocalStorageProp('playerTitle') title: string = '未在播放';
  @LocalStorageProp('playerArtist') artist: string = '';
  @LocalStorageProp('playerPlaying') playing: boolean = false;
  @LocalStorageProp('playerLoading') loading: boolean = false;
  @LocalStorageProp('playerLyric') lyric: string = '';

  /** 卡片上要显示的副文本：播放中滚动显示当前歌词行，安静时显示歌手 */
  private subText(): string {
    if (this.playing && this.lyric.length > 0) {
      return this.lyric;
    }
    return this.artist.length > 0 ? this.artist : '点击开始播放';
  }

  /** 后台控制命令：call 动作把命令送进主进程，不闪界面 */
  private call(cmd: string): void {
    postCardAction(this, {
      'action': 'call',
      'abilityName': 'EntryAbility',
      'params': { 'method': cmd }
    });
  }

  build() {
    Column() {
      Row() {
        // 封面占位
        Column() {
          Text('♪')
            .fontSize(22).fontFamily(APP_FONT)
            .fontColor(this.playing ? '#FF6470' : '#7A7A86')
        }
        .width(44).height(44)
        .borderRadius(12)
        .backgroundColor('#1C1C24')
        .justifyContent(FlexAlign.Center)

        Column() {
          Text(this.title.length > 0 ? this.title : '未在播放')
            .fontSize(13).fontFamily(APP_FONT_BOLD).fontWeight(FontWeight.Medium)
            .fontColor('#E8E8EC')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.subText())
            .fontSize(10).fontFamily(APP_FONT)
            .fontColor('#8A8A94')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 })
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)

      // 控制行：上一首 / 播放暂停 / 下一首
      Row() {
        Image($r('app.media.ic_prev'))
          .width(20).height(20)
          .onClick(() => {
            this.call('prev');
          })
        Image(this.playing ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
          .width(30).height(30)
          .margin({ left: 26, right: 26 })
          .onClick(() => {
            this.call('togglePlay');
          })
        Image($r('app.media.ic_next'))
          .width(20).height(20)
          .onClick(() => {
            this.call('next');
          })
      }
      .height(40)
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%').height('100%')
    .padding(12)
    .backgroundColor('#0D0D0F')
    .borderRadius(16)
    .onClick(() => {
      postCardAction(this, {
        'action': 'router',
        'abilityName': 'EntryAbility',
        'params': { 'method': 'openNowPlaying' }
      });
    })
  }
}
