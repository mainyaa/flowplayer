/*!
 Flowplayer : The Video Player for Web

 Copyright (c) 2012 - 2014 Flowplayer Ltd
 http://flowplayer.org

 Authors: Tero Piirainen, Anssi Piirainen

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
    import flash.display.DisplayObject;
    import flash.display.Sprite;
    import flash.display.StageAlign;
    import flash.display.StageScaleMode;
    import flash.display.*;
    import flash.events.*;
    import flash.net.URLLoader;
    import flash.net.URLStream;
    import flash.utils.getTimer;
    import flash.utils.setTimeout;
    import org.mangui.hls.event.HLSError;
    import org.mangui.hls.event.HLSEvent;
    import org.mangui.hls.HLS;
    import org.mangui.hls.HLSSettings;
    import org.mangui.hls.model.AudioTrack;
    import org.mangui.hls.model.Level;
    import org.mangui.hls.utils.JSURLLoader;
    import org.mangui.hls.utils.JSURLStream;
    import org.mangui.hls.utils.Log;
    import org.mangui.hls.utils.ScaleVideo;
    import org.mangui.chromeless.StatsHandler;
    import flash.external.ExternalInterface;
    import flash.media.SoundTransform;
    import flash.media.StageVideo;
    import flash.media.StageVideoAvailability;
    import flash.media.Video;
    import flash.system.Security;
    import flash.geom.Rectangle;

    public class Flowplayer extends Sprite {
        // events
        internal static const PLAY : String = "play";
        internal static const READY : String = "ready";
        internal static const PAUSE : String = "pause";
        internal static const RESUME : String = "resume";
        internal static const SEEK : String = "seek";
        internal static const STATUS : String = "status";
        internal static const BUFFERED : String = "buffered";
        internal static const VOLUME : String = "volume";
        internal static const FINISH : String = "finish";
        internal static const UNLOAD : String = "unload";
        internal static const ERROR : String = "error";
        internal static const SET : String = "set";
        internal static const GET : String = "get";
        // external interface
        private static const INTERFACE : Array = new Array(PLAY, PAUSE, RESUME, SEEK, VOLUME, UNLOAD, STATUS, SET, GET);
        // flashvars
        private var conf : Object;
        // state
        private var preloadComplete : Boolean;
        private var paused : Boolean;
        private var video : Video;
        private var logo : DisplayObject;
        private var provider : StreamProvider;
        /** Sheet to place on top of the video. **/
        protected var _sheet : Sprite;
        /** Reference to the stage video element. **/
        protected var _stageVideo : StageVideo = null;
        /** Reference to the video element. **/
        protected var _video : Video = null;
        /** Video size **/
        protected var _videoWidth : int = 0;
        protected var _videoHeight : int = 0;
        /** current media position */
        protected var _mediaPosition : Number;
        protected var _duration : Number;
        /** URL autoload feature */
        protected var _autoLoad : Boolean = false;
        /* JS callback name */
        protected var _callbackName : String;
        /* stats handler */
        private var _statsHandler : StatsHandler;


        /* constructor */
        public function Flowplayer() {
            Security.allowDomain("*");
            stage.scaleMode = StageScaleMode.NO_SCALE;
            stage.align = StageAlign.TOP_LEFT;

            var swfUrl : String = decodeURIComponent(this.loaderInfo.url);
            if (swfUrl.indexOf("callback=") > 0) throw new Error("Security error");

            configure();

            // IE needs mouse / keyboard events
            stage.addEventListener(MouseEvent.CLICK, function(e : MouseEvent) : void {
                fire("click", null);
            });

            stage.addEventListener(KeyboardEvent.KEY_DOWN, function(e : KeyboardEvent) : void {
                fire("keydown", e.keyCode);
            });

            stage.addEventListener(Event.RESIZE, arrange);
            stage.addEventListener(Event.RESIZE, _onStageResize);

            var player : Flowplayer = this;
            // The API
            for (var i : Number = 0; i < INTERFACE.length; i++) {
                debug("creating callback " + INTERFACE[i] + " id == " + ExternalInterface.objectID);
                ExternalInterface.addCallback("__" + INTERFACE[i], player[INTERFACE[i]]);
            }
            init();

            initProvider(); 
            _setupStage();
            _setupSheet();
            _setupExternalGetters();
            _setupExternalCallers();
            _setupExternalCallback();

            setTimeout(_pingJavascript, 50);
        }

        public function set(key : String, value : String) : void {
            debug('set: ' + key + ':' + value);
            if (value === "false") conf[key] = false;
            else if (value === "null") conf[key] = null;
            else conf[key] = value;
            if (CONFIG::HLS) {
              if (key.indexOf("hls_") !== -1 && provider is HLSStreamProvider) {
                provider.setProviderParam(key.substr(4), value);
              }
            }
        }

        public function get(key : String) : String {
          debug('get: ' + key);
          return conf[key];
        }

        /************ Public API ************/
        // switch url
        public function play(url : String, reconnect : Boolean) : void {
            debug("play(" + url + ", " + reconnect + ")");
            conf.url = encodeURI(url);
            debug("debug.url", conf.url);
            if (reconnect || providerChangeNeeded(url)) {
              initProvider();
            } else {
              provider.play(conf.url);
            }
            return;
        }

        public function resize() : void {
            debug('Flowplayer::resize()');
            var video : Video = provider.video;
            var rect : Rectangle = resizeRectangle();
            video.width = rect.width;
            video.height = rect.height;
            video.x = rect.x;
            video.y = rect.y;
        }


        public function pause() : void {
            debug("pause()");
            provider.pause();
            return;
        }

        public function resume() : void {
            debug("resume()");
            provider.resume();
            return;
        }

        public function seek(seconds : Number) : void {
            debug("seek(" + seconds + ")");
            provider.seek(seconds);
            return;
        }

        public function volume(level : Number, fireEvent : Boolean = true) : void {
            debug("volume(" + level + ")");
            provider.volume(level, fireEvent);
            return;
        }

        public function unload() : void {
            debug("unload()");
            provider.unload();
            return;
        }

        public function status() : Object {
            if (! provider) return null;
            return provider.status();
        }

        /************* Private API ***********/
        private function init() : void {
            debug("init()", conf);
            video = new Video();
            video.smoothing = true;
            this.addChild(video);
            logo = new Logo();
            addLogo();
            arrange();

            conf.url = encodeURI(conf.url);
            debug("debug.url", conf.url);

            paused = !conf.autoplay;
            preloadComplete = false;
        }

        private function providerChangeNeeded(url: String) : Boolean {
            if (!CONFIG::HLS) return false;
            else {
              return (url.indexOf(".m3u") != -1 && provider is NetStreamProvider) ||
                  (url.indexOf('.m3u') == -1 && !(provider is NetStreamProvider));
            }
        }
        // Adapted from https://github.com/mangui/flashls/blob/dev/src/org/mangui/hls/utils/ScaleVideo.as
        private function resizeRectangle() : Rectangle {
          var video : Video = provider.video,
              videoWidth : int = video.videoWidth,
              videoHeight : int = video.videoHeight,
              containerWidth : int = stage.stageWidth,
              containerHeight : int = stage.stageHeight;
          var rect : Rectangle = new Rectangle();
          var xscale : Number = containerWidth / videoWidth;
          var yscale : Number = containerHeight / videoHeight;
          if (xscale >= yscale) {
              rect.width = Math.min(videoWidth * yscale, containerWidth);
              rect.height = videoHeight * yscale;
          } else {
              rect.width = Math.min(videoWidth * xscale, containerWidth);
              rect.height = videoHeight * xscale;
          }
          rect.width = Math.ceil(rect.width);
          rect.height = Math.ceil(rect.height);
          rect.x = Math.round((containerWidth - rect.width) / 2);
          rect.y = Math.round((containerHeight - rect.height) / 2);
          return rect;
        }

        private function initProvider() : void {
            if (provider) provider.unload();
            // setup provider from URL
            if (CONFIG::HLS) {
                // detect HLS by checking the extension of src
                if (conf.url.indexOf(".m3u") != -1) {
                    debug("HLS stream detected!");
                    provider = new HLSStreamProvider(this, video);
                    for (var key : String in conf) {
                      if (key.indexOf("hls_") !== -1) {
                        provider.setProviderParam(key.substr(4), conf[key]);
                      }
                    }
                } else {
                    provider = new NetStreamProvider(this, video);
                }
            } else {
                provider = new NetStreamProvider(this, video);
            }
            provider.load(conf);
        }

        internal function debug(msg : String, data : Object = null) : void {
            if (!conf.debug) return;
            fire("debug: " + msg, data);
            // ExternalInterface.call("console.log", msg, data);
        }

        internal function fire(type : String, data : Object = null) : void {
            if (conf.callback) {
                if (data !== null) {
                    ExternalInterface.call(conf.callback, type, data);
                } else {
                    ExternalInterface.call(conf.callback, type);
                }
            }
        }

        private function arrange(e : Event = null) : void {
            logo.x = 12;
            logo.y = stage.stageHeight - 50;
            video.width = stage.stageWidth;
            video.height = stage.stageHeight;
        };

        private function _onStageResize(e: Event) : void {
          debug('Stage resized');
          resize();
        }

        private function addLogo() : void {
            var url : String = (conf.rtmp) ? conf.rtmp : unescape(conf.url) ? unescape(conf.url) : '';
            var pos : Number;
            var whitelist : Array = ['drive.flowplayer.org', 'drive.dev.flowplayer.org', 'my.flowplayer.org', 'rtmp.flowplayer.org'];

            for each (var wl : String in whitelist) {
                pos = url.indexOf('://' + wl)
                if (pos == 4 || pos == 5) return;
                // from flowplayer Drive
            }

            addChild(logo);
        }

        private function configure() : void {
            conf = this.loaderInfo.parameters;

            function decode(prop : String) : void {
                if (conf[prop] == "false") {
                    conf[prop] = false;
                    return;
                }
                conf[prop] = !!conf[prop];
            }
            if (conf.rtmpt == undefined) {
                conf.rtmpt = true;
            }
            if (conf.rtmp && conf.rtmp.indexOf("rtmp") < 0) {
                delete conf.rtmp;
            }

            decode("rtmpt");
            decode("live");
            decode("splash");
            decode("debug");
            decode("subscribe");
            decode("loop");
            decode("autoplay");
            debug("configure()", conf);
        }

        protected function _setupExternalGetters() : void {
            ExternalInterface.addCallback("getCurrentLevel", _getCurrentLevel);
            ExternalInterface.addCallback("getNextLevel", _getNextLevel);
            ExternalInterface.addCallback("getLoadLevel", _getLoadLevel);
            ExternalInterface.addCallback("getLevels", _getLevels);
            ExternalInterface.addCallback("getAutoLevel", _getAutoLevel);
            ExternalInterface.addCallback("getDuration", _getDuration);
            ExternalInterface.addCallback("getPosition", _getPosition);
            ExternalInterface.addCallback("getPlaybackState", _getPlaybackState);
            ExternalInterface.addCallback("getSeekState", _getSeekState);
            ExternalInterface.addCallback("getType", _getType);
            ExternalInterface.addCallback("getmaxBufferLength", _getmaxBufferLength);
            ExternalInterface.addCallback("getminBufferLength", _getminBufferLength);
            ExternalInterface.addCallback("getlowBufferLength", _getlowBufferLength);
            ExternalInterface.addCallback("getmaxBackBufferLength", _getmaxBackBufferLength);
            ExternalInterface.addCallback("getbufferLength", _getbufferLength);
            ExternalInterface.addCallback("getbackBufferLength", _getbackBufferLength);
            ExternalInterface.addCallback("getLogDebug", _getLogDebug);
            ExternalInterface.addCallback("getLogDebug2", _getLogDebug2);
            ExternalInterface.addCallback("getUseHardwareVideoDecoder", _getUseHardwareVideoDecoder);
            ExternalInterface.addCallback("getCapLeveltoStage", _getCapLeveltoStage);
            ExternalInterface.addCallback("getAutoLevelCapping", _getAutoLevelCapping);
            ExternalInterface.addCallback("getflushLiveURLCache", _getflushLiveURLCache);
            ExternalInterface.addCallback("getstartFromLevel", _getstartFromLevel);
            ExternalInterface.addCallback("getseekFromLowestLevel", _getseekFromLevel);
            ExternalInterface.addCallback("getJSURLStream", _getJSURLStream);
            ExternalInterface.addCallback("getPlayerVersion", _getPlayerVersion);
            ExternalInterface.addCallback("getAudioTrackList", _getAudioTrackList);
            ExternalInterface.addCallback("getAudioTrackId", _getAudioTrackId);
            ExternalInterface.addCallback("getStats", _getStats);
        };

        protected function _setupExternalCallers() : void {
            ExternalInterface.addCallback("playerLoad", _load);
            ExternalInterface.addCallback("playerPlay", _play);
            ExternalInterface.addCallback("playerPause", _pause);
            ExternalInterface.addCallback("playerResume", _resume);
            ExternalInterface.addCallback("playerSeek", _seek);
            ExternalInterface.addCallback("playerStop", _stop);
            ExternalInterface.addCallback("playerVolume", _volume);
            ExternalInterface.addCallback("playerSetCurrentLevel", _setCurrentLevel);
            ExternalInterface.addCallback("playerSetNextLevel", _setNextLevel);
            ExternalInterface.addCallback("playerSetLoadLevel", _setLoadLevel);
            ExternalInterface.addCallback("playerSetmaxBufferLength", _setmaxBufferLength);
            ExternalInterface.addCallback("playerSetminBufferLength", _setminBufferLength);
            ExternalInterface.addCallback("playerSetlowBufferLength", _setlowBufferLength);
            ExternalInterface.addCallback("playerSetbackBufferLength", _setbackBufferLength);
            ExternalInterface.addCallback("playerSetflushLiveURLCache", _setflushLiveURLCache);
            ExternalInterface.addCallback("playerSetstartFromLevel", _setstartFromLevel);
            ExternalInterface.addCallback("playerSetseekFromLevel", _setseekFromLevel);
            ExternalInterface.addCallback("playerSetLogDebug", _setLogDebug);
            ExternalInterface.addCallback("playerSetLogDebug2", _setLogDebug2);
            ExternalInterface.addCallback("playerSetUseHardwareVideoDecoder", _setUseHardwareVideoDecoder);
            ExternalInterface.addCallback("playerSetAutoLevelCapping", _setAutoLevelCapping);
            ExternalInterface.addCallback("playerCapLeveltoStage", _setCapLeveltoStage);
            ExternalInterface.addCallback("playerSetAudioTrack", _setAudioTrack);
            ExternalInterface.addCallback("playerSetJSURLStream", _setJSURLStream);
        };

        protected function _setupExternalCallback() : void {
            // Pass in the JavaScript callback name in the `callback` FlashVars parameter.
            _callbackName = LoaderInfo(this.root.loaderInfo).parameters.callback.toString();
        };

        protected function _setupStage() : void {
            stage.scaleMode = StageScaleMode.NO_SCALE;
            stage.align = StageAlign.TOP_LEFT;
            stage.fullScreenSourceRect = new Rectangle(0, 0, stage.stageWidth, stage.stageHeight);
            stage.addEventListener(StageVideoAvailabilityEvent.STAGE_VIDEO_AVAILABILITY, _onStageVideoState);
        }

        protected function _setupSheet() : void {
            // Draw sheet for catching clicks
            _sheet = new Sprite();
            _sheet.graphics.beginFill(0x000000, 0);
            _sheet.graphics.drawRect(0, 0, stage.stageWidth, stage.stageHeight);
            _sheet.addEventListener(MouseEvent.CLICK, _clickHandler);
            _sheet.buttonMode = true;
            addChild(_sheet);
        }

        protected function _trigger(event : String, ...args) : void {
            if (ExternalInterface.available) {
                ExternalInterface.call(_callbackName, event, args);
            }
        };

        /** Notify javascript the framework is ready. **/
        protected function _pingJavascript() : void {
            _trigger("ready", getTimer());
        };

        /** Forward events from the framework. **/
        protected function _completeHandler(event : HLSEvent) : void {
            _trigger("complete");
        };

        protected function _errorHandler(event : HLSEvent) : void {
            var hlsError : HLSError = event.error;
            _trigger("error", hlsError.code, hlsError.url, hlsError.msg);
        };

        protected function _levelLoadedHandler(event : HLSEvent) : void {
            _trigger("levelLoaded", event.loadMetrics);
        };

        protected function _audioLevelLoadedHandler(event : HLSEvent) : void {
            _trigger("audioLevelLoaded", event.loadMetrics);
        };

        protected function _fragmentLoadedHandler(event : HLSEvent) : void {
            _trigger("fragmentLoaded", event.loadMetrics);
        };

        protected function _fragmentPlayingHandler(event : HLSEvent) : void {
            _trigger("fragmentPlaying", event.playMetrics);
        };

        protected function _manifestLoadedHandler(event : HLSEvent) : void {
            _duration = event.levels[provider.hls.startLevel].duration;

            if (_autoLoad) {
                _play(-1);
            }

            _trigger("manifest", _duration, event.levels, event.loadMetrics);
        };

        protected function _mediaTimeHandler(event : HLSEvent) : void {
            _duration = event.mediatime.duration;
            _mediaPosition = event.mediatime.position;
            //_trigger("position", event.mediatime);

            var videoWidth : int = _video ? _video.videoWidth : _stageVideo.videoWidth;
            var videoHeight : int = _video ? _video.videoHeight : _stageVideo.videoHeight;

            if (videoWidth && videoHeight) {
                var changed : Boolean = _videoWidth != videoWidth || _videoHeight != videoHeight;
                if (changed) {
                    _videoHeight = videoHeight;
                    _videoWidth = videoWidth;
                    _resize();
                    _trigger("videoSize", _videoWidth, _videoHeight);
                }
            }
        };

        protected function _playbackStateHandler(event : HLSEvent) : void {
            _trigger("state", event.state);
        };

        protected function _seekStateHandler(event : HLSEvent) : void {
            _trigger("seekState", event.state);
        };

        protected function _levelSwitchHandler(event : HLSEvent) : void {
            _trigger("switch", event.level);
        };

        protected function _fpsDropHandler(event : HLSEvent) : void {
            _trigger("fpsDrop", event.level);
        };

        protected function _fpsDropLevelCappingHandler(event : HLSEvent) : void {
            _trigger("fpsDropLevelCapping", event.level);
        };

        protected function _fpsDropSmoothLevelSwitchHandler(event : HLSEvent) : void {
            _trigger("fpsDropSmoothLevelSwitch");
        };

        protected function _audioTracksListChange(event : HLSEvent) : void {
            _trigger("audioTracksListChange", _getAudioTrackList());
        }

        protected function _audioTrackChange(event : HLSEvent) : void {
            _trigger("audioTrackChange", event.audioTrack);
        }

        protected function _id3Updated(event : HLSEvent) : void {
            _trigger("id3Updated", event.ID3Data);
        }

        /** Javascript getters. **/
        protected function _getCurrentLevel() : int {
            return provider.hls.currentLevel;
        };

        protected function _getNextLevel() : int {
            return provider.hls.nextLevel;
        };

        protected function _getLoadLevel() : int {
            return provider.hls.loadLevel;
        };

        protected function _getLevels() : Vector.<Level> {
            return provider.hls.levels;
        };

        protected function _getAutoLevel() : Boolean {
            return provider.hls.autoLevel;
        };

        protected function _getDuration() : Number {
            return _duration;
        };

        protected function _getPosition() : Number {
            return provider.hls.position;
        };

        protected function _getPlaybackState() : String {
            return provider.hls.playbackState;
        };

        protected function _getSeekState() : String {
            return provider.hls.seekState;
        };

        protected function _getType() : String {
            return provider.hls.type;
        };

        protected function _getbufferLength() : Number {
            return provider.hls.stream.bufferLength;
        };

        protected function _getbackBufferLength() : Number {
            return provider.hls.stream.backBufferLength;
        };

        protected function _getmaxBufferLength() : Number {
            return HLSSettings.maxBufferLength;
        };

        protected function _getminBufferLength() : Number {
            return HLSSettings.minBufferLength;
        };

        protected function _getlowBufferLength() : Number {
            return HLSSettings.lowBufferLength;
        };

        protected function _getmaxBackBufferLength() : Number {
            return HLSSettings.maxBackBufferLength;
        };

        protected function _getflushLiveURLCache() : Boolean {
            return HLSSettings.flushLiveURLCache;
        };

        protected function _getstartFromLevel() : int {
            return HLSSettings.startFromLevel;
        };

        protected function _getseekFromLevel() : int {
            return HLSSettings.seekFromLevel;
        };

        protected function _getLogDebug() : Boolean {
            return HLSSettings.logDebug;
        };

        protected function _getLogDebug2() : Boolean {
            return HLSSettings.logDebug2;
        };

        protected function _getUseHardwareVideoDecoder() : Boolean {
            return HLSSettings.useHardwareVideoDecoder;
        };

        protected function _getCapLeveltoStage() : Boolean {
            return HLSSettings.capLevelToStage;
        };

        protected function _getAutoLevelCapping() : int {
            return provider.hls.autoLevelCapping;
        };

        protected function _getJSURLStream() : Boolean {
            return (provider.hls.URLstream is JSURLStream);
        };

        protected function _getPlayerVersion() : Number {
            return 3;
        };

        protected function _getAudioTrackList() : Array {
            var list : Array = [];
            var vec : Vector.<AudioTrack> = provider.hls.audioTracks;
            for (var i : Object in vec) {
                list.push(vec[i]);
            }
            return list;
        };

        protected function _getAudioTrackId() : int {
            return provider.hls.audioTrack;
        };

        protected function _getStats() : Object {
            return _statsHandler.stats;
        };

        /** Javascript calls. **/
        protected function _load(url : String) : void {
            provider.hls.load(url);
        };

        protected function _play(position : Number = -1) : void {
            provider.hls.stream.play(null, position);
        };

        protected function _pause() : void {
            provider.hls.stream.pause();
        };

        protected function _resume() : void {
            provider.hls.stream.resume();
        };

        protected function _seek(position : Number) : void {
            provider.hls.stream.seek(position);
        };

        protected function _stop() : void {
            provider.hls.stream.close();
        };

        protected function _volume(percent : Number) : void {
            provider.hls.stream.soundTransform = new SoundTransform(percent / 100);
        };

        protected function _setCurrentLevel(level : int) : void {
            provider.hls.currentLevel = level;
        };

        protected function _setNextLevel(level : int) : void {
            provider.hls.nextLevel = level;
        };

        protected function _setLoadLevel(level : int) : void {
            provider.hls.loadLevel = level;
        };

        protected function _setmaxBufferLength(newLen : Number) : void {
            HLSSettings.maxBufferLength = newLen;
        };

        protected function _setminBufferLength(newLen : Number) : void {
            HLSSettings.minBufferLength = newLen;
        };

        protected function _setlowBufferLength(newLen : Number) : void {
            HLSSettings.lowBufferLength = newLen;
        };

        protected function _setbackBufferLength(newLen : Number) : void {
            HLSSettings.maxBackBufferLength = newLen;
        };

        protected function _setflushLiveURLCache(flushLiveURLCache : Boolean) : void {
            HLSSettings.flushLiveURLCache = flushLiveURLCache;
        };

        protected function _setstartFromLevel(startFromLevel : int) : void {
            HLSSettings.startFromLevel = startFromLevel;
        };

        protected function _setseekFromLevel(seekFromLevel : int) : void {
            HLSSettings.seekFromLevel = seekFromLevel;
        };

        protected function _setLogDebug(debug : Boolean) : void {
            HLSSettings.logDebug = debug;
        };

        protected function _setLogDebug2(debug2 : Boolean) : void {
            HLSSettings.logDebug2 = debug2;
        };

        protected function _setUseHardwareVideoDecoder(value : Boolean) : void {
            HLSSettings.useHardwareVideoDecoder = value;
        };

        protected function _setCapLeveltoStage(value : Boolean) : void {
            HLSSettings.capLevelToStage = value;
        };

        protected function _setAutoLevelCapping(value : int) : void {
            provider.hls.autoLevelCapping = value;
        };

        protected function _setJSURLStream(jsURLstream : Boolean) : void {
            if (jsURLstream) {
                provider.hls.URLstream = JSURLStream as Class;
                provider.hls.URLloader = JSURLLoader as Class;
                if (_callbackName) {
                    provider.hls.URLstream.externalCallback = _callbackName;
                    provider.hls.URLloader.externalCallback = _callbackName;
                }
            } else {
                provider.hls.URLstream = URLStream as Class;
                provider.hls.URLloader = URLLoader as Class;
            }
        };

        protected function _setAudioTrack(val : int) : void {
            if (val == provider.hls.audioTrack) return;
            provider.hls.audioTrack = val;
            if (!isNaN(_mediaPosition)) {
                provider.hls.stream.seek(_mediaPosition);
            }
        };

        /** Mouse click handler. **/
        protected function _clickHandler(event : MouseEvent) : void {
            if (stage.displayState == StageDisplayState.FULL_SCREEN_INTERACTIVE || stage.displayState == StageDisplayState.FULL_SCREEN) {
                stage.displayState = StageDisplayState.NORMAL;
            } else {
                stage.displayState = StageDisplayState.FULL_SCREEN;
            }
        };

        /** StageVideo detector. **/
        protected function _onStageVideoState(event : StageVideoAvailabilityEvent) : void {
            var available : Boolean = (event.availability == StageVideoAvailability.AVAILABLE);
            // set framerate to 60 fps
            stage.frameRate = 60;
            // set up stats handler
            _statsHandler = new StatsHandler(provider.hls);
            provider.hls.addEventListener(HLSEvent.PLAYBACK_COMPLETE, _completeHandler);
            provider.hls.addEventListener(HLSEvent.ERROR, _errorHandler);
            provider.hls.addEventListener(HLSEvent.FRAGMENT_LOADED, _fragmentLoadedHandler);
            provider.hls.addEventListener(HLSEvent.AUDIO_LEVEL_LOADED, _audioLevelLoadedHandler);
            provider.hls.addEventListener(HLSEvent.LEVEL_LOADED, _levelLoadedHandler);
            provider.hls.addEventListener(HLSEvent.FRAGMENT_PLAYING, _fragmentPlayingHandler);
            provider.hls.addEventListener(HLSEvent.MANIFEST_LOADED, _manifestLoadedHandler);
            provider.hls.addEventListener(HLSEvent.MEDIA_TIME, _mediaTimeHandler);
            provider.hls.addEventListener(HLSEvent.PLAYBACK_STATE, _playbackStateHandler);
            provider.hls.addEventListener(HLSEvent.SEEK_STATE, _seekStateHandler);
            provider.hls.addEventListener(HLSEvent.LEVEL_SWITCH, _levelSwitchHandler);
            provider.hls.addEventListener(HLSEvent.AUDIO_TRACKS_LIST_CHANGE, _audioTracksListChange);
            provider.hls.addEventListener(HLSEvent.AUDIO_TRACK_SWITCH, _audioTrackChange);
            provider.hls.addEventListener(HLSEvent.ID3_UPDATED, _id3Updated);
            provider.hls.addEventListener(HLSEvent.FPS_DROP, _fpsDropHandler);
            provider.hls.addEventListener(HLSEvent.FPS_DROP_LEVEL_CAPPING, _fpsDropLevelCappingHandler);
            provider.hls.addEventListener(HLSEvent.FPS_DROP_SMOOTH_LEVEL_SWITCH, _fpsDropSmoothLevelSwitchHandler);

            if (available && stage.stageVideos.length > 0) {
                _stageVideo = stage.stageVideos[0];
                _stageVideo.addEventListener(StageVideoEvent.RENDER_STATE, _onStageVideoStateChange)
                _stageVideo.viewPort = new Rectangle(0, 0, stage.stageWidth, stage.stageHeight);
                _stageVideo.attachNetStream(provider.hls.stream);
            } else {
                _video = new Video(stage.stageWidth, stage.stageHeight);
                _video.addEventListener(VideoEvent.RENDER_STATE, _onVideoStateChange);
                addChild(_video);
                _video.smoothing = true;
                _video.attachNetStream(provider.hls.stream);
            }
            stage.removeEventListener(StageVideoAvailabilityEvent.STAGE_VIDEO_AVAILABILITY, _onStageVideoState);

            var autoLoadUrl : String = root.loaderInfo.parameters.url as String;
            if (autoLoadUrl != null) {
                _autoLoad = true;
                _load(autoLoadUrl);
            }
        };

        private function _onStageVideoStateChange(event : StageVideoEvent) : void {
            Log.info("Video decoding:" + event.status);
        }

        private function _onVideoStateChange(event : VideoEvent) : void {
            Log.info("Video decoding:" + event.status);
        }

        protected function _resize() : void {
            var rect : Rectangle;
            rect = ScaleVideo.resizeRectangle(_videoWidth, _videoHeight, stage.stageWidth, stage.stageHeight);
            // resize video
            if (_video) {
                _video.width = rect.width;
                _video.height = rect.height;
                _video.x = rect.x;
                _video.y = rect.y;
            } else if (_stageVideo && rect.width > 0) {
                _stageVideo.viewPort = rect;
            }
        }

    }
}
