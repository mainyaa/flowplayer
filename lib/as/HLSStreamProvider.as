/*!
 Flowplayer : The Video Player for Web

 Copyright (c) 2014 Flowplayer Ltd
 http://flowplayer.org

 Authors: Guillaume du Pontavice

 -----

 This GPL version includes Flowplayer branding

 http://flowplayer.org/GPL-license/#term-7

 Commercial versions are available
 * part of the upgrade cycle
 * support the player development
 * no Flowplayer trademark

 http://flowplayer.org/pricing/
 */
package {
    import flash.events.Event;
    import flash.media.SoundTransform;

    import org.mangui.hls.event.HLSError;
    import org.mangui.hls.event.HLSEvent;
    import org.mangui.hls.constant.HLSPlayStates;
    import org.mangui.hls.constant.HLSSeekMode;
    import org.mangui.hls.HLSSettings;
    import org.mangui.hls.HLS;
    import org.mangui.hls.utils.Params2Settings;

    import flash.media.Video;

    public class HLSStreamProvider implements StreamProvider {
        private var _hls : HLS;
        // player/video object
        private var player : Flowplayer;
        private var _video : Video;
        private var config : Object;
        private var clip : Object;
        private var pos : Number;
        private var offsetPos : Number;
        private var backBuffer : Number;
        private var suppressReady : Boolean;

        public function HLSStreamProvider(player : Flowplayer, video : Video) {
            this.player = player;
            this._video = video;
            initHLS();
        }

        private function initHLS() : void {
            _hls = new HLS();
            _hls.stage = player.stage;
            /* force keyframe seek mode to avoid video glitches when seeking to a non-keyframe position */
            HLSSettings.seekMode = HLSSeekMode.KEYFRAME_SEEK;
            _hls.addEventListener(HLSEvent.MANIFEST_LOADED, _manifestHandler);
            _hls.addEventListener(HLSEvent.MEDIA_TIME, _mediaTimeHandler);
            _hls.addEventListener(HLSEvent.PLAYBACK_COMPLETE, _completeHandler);
            _hls.addEventListener(HLSEvent.ERROR, _errorHandler);
            _video.attachNetStream(_hls.stream);
        }

        public function get video() : Video {
          return this._video;
        }
        public function get hls() : HLS {
          return this._hls;
        }

        public function load(config : Object) : void {
            this.config = config;
            player.debug("loading URL " + config.url);
            _hls.load(config.url);
            clip = new Object();
        }

        public function unload() : void {
            _hls.removeEventListener(HLSEvent.MANIFEST_LOADED, _manifestHandler);
            _hls.removeEventListener(HLSEvent.MEDIA_TIME, _mediaTimeHandler);
            _hls.removeEventListener(HLSEvent.PLAYBACK_COMPLETE, _completeHandler);
            _hls.removeEventListener(HLSEvent.ERROR, _errorHandler);
            _hls.dispose();
            _hls = null;
            //player.fire(Flowplayer.UNLOAD, null);
        }

        public function play(url : String) : void {
            _hls.load(url);
            resume();
        }

        public function pause() : void {
            _hls.stream.pause();
            player.fire(Flowplayer.PAUSE, null);
        }

        public function resume() : void {
            player.debug('HLSStreamProvider::resume(), _hls.playbackState=%s, this.pos=%s, this.offsetPos=%s, this.backBuffer=%s', [_hls.playbackState, this.pos, this.offsetPos, this.backBuffer]);
            switch(_hls.playbackState) {
                case HLSPlayStates.IDLE:
                // in IDLE state, restart playback
                    _hls.stream.play(null,-1);
                    player.fire(Flowplayer.RESUME, null);
                    break;
                case HLSPlayStates.PAUSED:
                case HLSPlayStates.PAUSED_BUFFERING:
                    if (this.offsetPos + this.backBuffer < -1) {
                      player.debug('Stream idle for too long, restart stream');
                      unload();
                      suppressReady = true;
                      initHLS();
                      this.config.autoplay = true;
                      load(this.config);
                      break;
                    } else {
                      _hls.stream.resume();
                    }
                    player.fire(Flowplayer.RESUME, null);
                    break;
                // do nothing if already in play state
                //case HLSPlayStates.PLAYING:
                //case HLSPlayStates.PLAYING_BUFFERING:
                default:
                    break;
            }
        }

        public function seek(seconds : Number) : void {
            _hls.stream.seek(seconds);
            player.fire(Flowplayer.SEEK, seconds);
        }

        public function volume(level : Number, fireEvent : Boolean = true) : void {
            _hls.stream.soundTransform = new SoundTransform(level);
            if (fireEvent) {
                player.fire(Flowplayer.VOLUME, level);
            }
        }

        public function status() : Object {
            var pos : Number = this.pos;
            if (isNaN(pos) || pos < 0) {
                pos = 0;
            }
            return {time:pos, buffer:pos + _hls.stream.bufferLength};
        }

        public function setProviderParam(key:String, value:Object) : void {
            var decode : Function = function(value : String) : Object {
              if (value == "false") return false;
              if (!isNaN(Number(value))) return Number(value);
              if (value == "null") return null;
              return value;
            };
            player.debug("HLSStreamProvider::setProviderParam: " + key, decode(value));
            Params2Settings.set(key, decode(value));
        }

        /* private */
        private function _manifestHandler(event : HLSEvent) : void {
            clip.bytes = clip.duration = event.levels[_hls.startLevel].duration;
            clip.seekable = true;
            clip.src = clip.url = config.url;
            clip.width = event.levels[_hls.startLevel].width;
            clip.height = event.levels[_hls.startLevel].height;
            _checkVideoDimension();
            player.debug("manifest received " + clip);
            if (suppressReady) {
              suppressReady = false;
            } else {
              _hls.addEventListener(HLSEvent.PLAYBACK_STATE, _readyStateHandler);
            }

            _hls.stream.play();
            if (config.autoplay) {
            } else {
                player.debug("stopping on first frame");
                _hls.stream.pause();
            }
        };

        protected function _mediaTimeHandler(event : HLSEvent) : void {
            this.pos = event.mediatime.live_sliding_main + event.mediatime.position;
            this.offsetPos = event.mediatime.position;
            this.backBuffer = event.mediatime.backbuffer;
            _checkVideoDimension();
        };

        private function _checkVideoDimension() : void {
            var videoWidth : int = video.videoWidth;
            var videoHeight : int = video.videoHeight;

            if (videoWidth && videoHeight) {
                var changed : Boolean = clip.width != videoWidth || clip.height != videoHeight;
                if (changed) {
                    player.debug("video dimension changed");
                    _resize();
                }
            }
        }

        private function _resize() : void {
            player.debug("video/player size : " + video.videoWidth + "," + video.videoHeight + "/" + player.stage.stageWidth + "," + player.stage.stageHeight);
            clip.width = video.videoWidth;
            clip.height = video.videoHeight;
            player.resize(); 
        }

        private function _completeHandler(event : HLSEvent) : void {
            player.debug("playback complete,fire pause and finish events");
            player.fire(Flowplayer.PAUSE, null);
            player.fire(Flowplayer.FINISH, null);
        };

        private function _readyStateHandler(event: HLSEvent) : void {
          if (_hls.playbackState == HLSPlayStates.PLAYING || hls.playbackState == HLSPlayStates.PAUSED) {
            player.fire(Flowplayer.READY, clip);
            if (config.autoplay) {
                player.fire(Flowplayer.RESUME, null);
            }
            _hls.removeEventListener(HLSEvent.PLAYBACK_STATE, _readyStateHandler);
          }
        };

        private function _errorHandler(event : HLSEvent) : void {
            var hlsError : HLSError = event.error;
            player.debug("error (code/msg/url):" + hlsError.code + "/" + hlsError.msg + "/" + hlsError.url);
            player.fire(Flowplayer.ERROR, {code:4});
        };
    }
}
