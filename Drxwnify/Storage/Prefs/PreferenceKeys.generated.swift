// Сгенерировано scripts/gen_prefkeys.py из android/.../constants/PreferenceKeys.kt. Руками не править.
// Имена ключей совпадают с Android DataStore (settings.preferences_pb).

enum PK {
    /// EnableDynamicIconKey
    static let enableDynamicIcon = PrefKey<Bool>("enableDynamicIcon", .bool)
    /// EnableHighRefreshRateKey
    static let enableHighRefreshRate = PrefKey<Bool>("enableHighRefreshRate", .bool)
    /// DynamicThemeKey
    static let dynamicTheme = PrefKey<Bool>("dynamicTheme", .bool)
    /// SelectedThemeColorKey
    static let selectedThemeColor = PrefKey<Int>("selectedThemeColor", .int)
    /// DarkModeKey
    static let darkMode = PrefKey<String>("darkMode", .string)
    /// AppThemePresetKey
    static let appThemePreset = PrefKey<String>("appThemePreset", .string)
    /// ThemeAnimationsKey
    static let themeAnimations = PrefKey<Bool>("themeAnimations", .bool)
    /// AppIconKey
    static let appIcon = PrefKey<String>("appIcon", .string)
    /// PureBlackKey
    static let pureBlack = PrefKey<Bool>("pureBlack", .bool)
    /// PureBlackMiniPlayerKey
    static let pureBlackMiniPlayer = PrefKey<Bool>("pureBlackMiniPlayer", .bool)
    /// MiniPlayerOutlineKey
    static let miniPlayerOutline = PrefKey<Bool>("miniPlayerOutline", .bool)
    /// MiniPlayerBackgroundStyleKey
    static let miniPlayerBackgroundStyle = PrefKey<String>("miniPlayerBackgroundStyle", .string)
    /// DensityScaleKey
    static let densityScaleFactor = PrefKey<Float>("density_scale_factor", .float)
    /// CustomDensityScaleKey
    static let customDensityScaleValue = PrefKey<Float>("custom_density_scale_value", .float)
    /// DefaultOpenTabKey
    static let defaultOpenTab = PrefKey<String>("defaultOpenTab", .string)
    /// SlimNavBarKey
    static let slimNavBar = PrefKey<Bool>("slimNavBar", .bool)
    /// GridItemsSizeKey
    static let gridItemSize = PrefKey<String>("gridItemSize", .string)
    /// SliderStyleKey
    static let sliderStyle = PrefKey<String>("sliderStyle", .string)
    /// SquigglySliderKey
    static let squigglySlider = PrefKey<Bool>("squigglySlider", .bool)
    /// SwipeToSongKey
    static let swipeToSong = PrefKey<Bool>("SwipeToSong", .bool)
    /// SwipeToRemoveSongKey
    static let swipeToRemoveSong = PrefKey<Bool>("SwipeToRemoveSong", .bool)
    /// UseNewPlayerDesignKey
    static let useNewPlayerDesign = PrefKey<Bool>("useNewPlayerDesign", .bool)
    /// UseNewMiniPlayerDesignKey
    static let useNewMiniPlayerDesign = PrefKey<Bool>("useNewMiniPlayerDesign", .bool)
    /// HidePlayerThumbnailKey
    static let hidePlayerThumbnail = PrefKey<Bool>("hidePlayerThumbnail", .bool)
    /// CropAlbumArtKey
    static let cropAlbumArt = PrefKey<Bool>("cropAlbumArt", .bool)
    /// SeekExtraSeconds
    static let seekExtraSeconds = PrefKey<Bool>("seekExtraSeconds", .bool)
    /// PauseOnMute
    static let pauseOnMute = PrefKey<Bool>("pauseOnMute", .bool)
    /// ResumeOnBluetoothConnectKey
    static let resumeOnBluetoothConnect = PrefKey<Bool>("resumeOnBluetoothConnect", .bool)
    /// KeepScreenOn
    static let keepScreenOn = PrefKey<Bool>("keepScreenOn", .bool)
    /// AlarmEnabledKey
    static let alarmEnabled = PrefKey<Bool>("alarmEnabled", .bool)
    /// AlarmHourKey
    static let alarmHour = PrefKey<Int>("alarmHour", .int)
    /// AlarmMinuteKey
    static let alarmMinute = PrefKey<Int>("alarmMinute", .int)
    /// AlarmPlaylistIdKey
    static let alarmPlaylistId = PrefKey<String>("alarmPlaylistId", .string)
    /// AlarmRandomSongKey
    static let alarmRandomSong = PrefKey<Bool>("alarmRandomSong", .bool)
    /// AlarmNextTriggerAtKey
    static let alarmNextTriggerAt = PrefKey<Int>("alarmNextTriggerAt", .long)
    /// AlarmEntriesKey
    static let alarmEntries = PrefKey<String>("alarmEntries", .string)
    /// DeveloperModeKey
    static let developerMode = PrefKey<Bool>("developerMode", .bool)
    /// AppLanguageKey
    static let appLanguage = PrefKey<String>("appLanguage", .string)
    /// ContentLanguageKey
    static let contentLanguage = PrefKey<String>("contentLanguage", .string)
    /// ContentCountryKey
    static let contentCountry = PrefKey<String>("contentCountry", .string)
    /// EnableKugouKey
    static let enableKugou = PrefKey<Bool>("enableKugou", .bool)
    /// EnableLrcLibKey
    static let enableLrclib = PrefKey<Bool>("enableLrclib", .bool)
    /// EnableBetterLyricsKey
    static let enableBetterLyrics = PrefKey<Bool>("enableBetterLyrics", .bool)
    /// EnablePaxsenixKey
    static let enablePaxsenix = PrefKey<Bool>("enablePaxsenix", .bool)
    /// EnableLyricsPlus
    static let enableLyricsPlus = PrefKey<Bool>("enableLyricsPlus", .bool)
    /// EnableMusixmatchKey
    static let enableMusixmatch = PrefKey<Bool>("enableMusixmatch", .bool)
    /// HideExplicitKey
    static let hideExplicit = PrefKey<Bool>("hideExplicit", .bool)
    /// HideVideoSongsKey
    static let hideVideoSongs = PrefKey<Bool>("hideVideoSongs", .bool)
    /// HideYoutubeShortsKey
    static let hideYoutubeShorts = PrefKey<Bool>("hideYoutubeShorts", .bool)
    /// ShowArtistDescriptionKey
    static let showArtistDescription = PrefKey<Bool>("showArtistDescription", .bool)
    /// ShowArtistSubscriberCountKey
    static let showArtistSubscriberCount = PrefKey<Bool>("showArtistSubscriberCount", .bool)
    /// ShowMonthlyListenersKey
    static let showMonthlyListeners = PrefKey<Bool>("showMonthlyListeners", .bool)
    /// ProxyEnabledKey
    static let proxyEnabled = PrefKey<Bool>("proxyEnabled", .bool)
    /// ProxyUrlKey
    static let proxyUrl = PrefKey<String>("proxyUrl", .string)
    /// ProxyTypeKey
    static let proxyType = PrefKey<String>("proxyType", .string)
    /// ProxyUsernameKey
    static let proxyUsername = PrefKey<String>("proxyUsername", .string)
    /// ProxyPasswordKey
    static let proxyPassword = PrefKey<String>("proxyPassword", .string)
    /// YtmSyncKey
    static let ytmSync = PrefKey<Bool>("ytmSync", .bool)
    /// SelectedYtmPlaylistsKey
    static let selectedYtmPlaylists = PrefKey<String>("selectedYtmPlaylists", .string)
    /// CheckForUpdatesKey
    static let checkForUpdates = PrefKey<Bool>("checkForUpdates", .bool)
    /// UpdateNotificationsEnabledKey
    static let updateNotifications = PrefKey<Bool>("updateNotifications", .bool)
    /// LastUpdateCheckTimeKey
    static let lastUpdateCheckTime = PrefKey<Int>("lastUpdateCheckTime", .long)
    /// AudioQualityKey
    static let audioQuality = PrefKey<String>("audioQuality", .string)
    /// AudioOffload
    static let enableOffload = PrefKey<Bool>("enableOffload", .bool)
    /// VarispeedKey
    static let varispeed = PrefKey<Bool>("varispeed", .bool)
    /// PersistentQueueKey
    static let persistentQueue = PrefKey<Bool>("persistentQueue", .bool)
    /// PersistentShuffleAcrossQueuesKey
    static let persistentShuffleAcrossQueues = PrefKey<Bool>("persistentShuffleAcrossQueues", .bool)
    /// RememberShuffleAndRepeatKey
    static let rememberShuffleAndRepeat = PrefKey<Bool>("rememberShuffleAndRepeat", .bool)
    /// ShuffleModeKey
    static let shuffleMode = PrefKey<Bool>("shuffleMode", .bool)
    /// SkipSilenceKey
    static let skipSilence = PrefKey<Bool>("skipSilence", .bool)
    /// SkipSilenceInstantKey
    static let skipSilenceInstant = PrefKey<Bool>("skipSilenceInstant", .bool)
    /// AudioNormalizationKey
    static let audioNormalization = PrefKey<Bool>("audioNormalization", .bool)
    /// AudioFocusEnabledKey
    static let audioFocusEnabled = PrefKey<Bool>("audioFocusEnabled", .bool)
    /// AutoLoadMoreKey
    static let autoLoadMore = PrefKey<Bool>("autoLoadMore", .bool)
    /// DisableLoadMoreWhenRepeatAllKey
    static let disableLoadMoreWhenRepeatAll = PrefKey<Bool>("disableLoadMoreWhenRepeatAll", .bool)
    /// AutoDownloadOnLikeKey
    static let autoDownloadOnLike = PrefKey<Bool>("autoDownloadOnLike", .bool)
    /// SimilarContent
    static let similarContent = PrefKey<Bool>("similarContent", .bool)
    /// AutoSkipNextOnErrorKey
    static let autoSkipNextOnError = PrefKey<Bool>("autoSkipNextOnError", .bool)
    /// StopMusicOnTaskClearKey
    static let stopMusicOnTaskClear = PrefKey<Bool>("stopMusicOnTaskClear", .bool)
    /// ShufflePlaylistFirstKey
    static let shufflePlaylistFirst = PrefKey<Bool>("shufflePlaylistFirst", .bool)
    /// PreventDuplicateTracksInQueueKey
    static let preventDuplicateTracksInQueue = PrefKey<Bool>("preventDuplicateTracksInQueue", .bool)
    /// CrossfadeEnabledKey
    static let crossfadeEnabled = PrefKey<Bool>("crossfadeEnabled", .bool)
    /// CrossfadeDurationKey
    static let crossfadeDurationFloat = PrefKey<Float>("crossfadeDurationFloat", .float)
    /// CrossfadeGaplessKey
    static let crossfadeGapless = PrefKey<Bool>("crossfadeGapless", .bool)
    /// MaxImageCacheSizeKey
    static let maxImageCacheSize = PrefKey<Int>("maxImageCacheSize", .int)
    /// MaxSongCacheSizeKey
    static let maxSongCacheSize = PrefKey<Int>("maxSongCacheSize", .int)
    /// EnableSongCacheKey
    static let enableSongCache = PrefKey<Bool>("enableSongCache", .bool)
    /// PreCacheTracksKey
    static let preCacheTracks = PrefKey<Int>("preCacheTracks", .int)
    /// PreCacheOnlyWifiKey
    static let preCacheOnlyWifi = PrefKey<Bool>("preCacheOnlyWifi", .bool)
    /// DownloadFolderUriKey
    static let downloadFolderUri = PrefKey<String>("downloadFolderUri", .string)
    /// ExportedSongIdsKey
    static let exportedSongIds = PrefKey<[String]>("exportedSongIds", .stringSet)
    /// ExportedUrisKey
    static let exportedSongUris = PrefKey<[String]>("exportedSongUris", .stringSet)
    /// PendingExportSongIdsKey
    static let pendingExportSongIds = PrefKey<[String]>("pendingExportSongIds", .stringSet)
    /// ExportFolderHintsKey
    static let exportFolderHints = PrefKey<[String]>("exportFolderHints", .stringSet)
    /// PauseListenHistoryKey
    static let pauseListenHistory = PrefKey<Bool>("pauseListenHistory", .bool)
    /// PauseSearchHistoryKey
    static let pauseSearchHistory = PrefKey<Bool>("pauseSearchHistory", .bool)
    /// DisableScreenshotKey
    static let disableScreenshot = PrefKey<Bool>("disableScreenshot", .bool)
    /// CrashReportingEnabledKey
    static let crashReportingEnabled = PrefKey<Bool>("crashReportingEnabled", .bool)
    /// DiscordTokenKey
    static let discordToken = PrefKey<String>("discordToken", .string)
    /// DiscordInfoDismissedKey
    static let discordInfoDismissed = PrefKey<Bool>("discordInfoDismissed", .bool)
    /// DiscordUsernameKey
    static let discordUsername = PrefKey<String>("discordUsername", .string)
    /// DiscordNameKey
    static let discordName = PrefKey<String>("discordName", .string)
    /// EnableDiscordRPCKey
    static let discordRPCEnable = PrefKey<Bool>("discordRPCEnable", .bool)
    /// DiscordUseDetailsKey
    static let discordUseDetails = PrefKey<Bool>("discordUseDetails", .bool)
    /// DiscordAvatarKey
    static let discordAvatar = PrefKey<String>("discordAvatar", .string)
    /// DiscordStatusKey
    static let discordStatus = PrefKey<String>("discordStatus", .string)
    /// DiscordButton1TextKey
    static let discordButton1Text = PrefKey<String>("discordButton1Text", .string)
    /// DiscordButton1VisibleKey
    static let discordButton1Visible = PrefKey<Bool>("discordButton1Visible", .bool)
    /// DiscordButton1UrlKey
    static let discordButton1Url = PrefKey<String>("discordButton1Url", .string)
    /// DiscordButton2TextKey
    static let discordButton2Text = PrefKey<String>("discordButton2Text", .string)
    /// DiscordButton2VisibleKey
    static let discordButton2Visible = PrefKey<Bool>("discordButton2Visible", .bool)
    /// DiscordButton2UrlKey
    static let discordButton2Url = PrefKey<String>("discordButton2Url", .string)
    /// DiscordActivityTypeKey
    static let discordActivityType = PrefKey<String>("discordActivityType", .string)
    /// DiscordActivityNameKey
    static let discordActivityName = PrefKey<String>("discordActivityName", .string)
    /// DiscordAdvancedModeKey
    static let discordAdvancedMode = PrefKey<Bool>("discordAdvancedMode", .bool)
    /// EnableGoogleCastKey
    static let enableGoogleCast = PrefKey<Bool>("enableGoogleCast", .bool)
    /// ListenTogetherServerUrlKey
    static let listenTogetherServerUrl = PrefKey<String>("listenTogetherServerUrl", .string)
    /// ListenTogetherUsernameKey
    static let listenTogetherUsername = PrefKey<String>("listenTogetherUsername", .string)
    /// EnableListenTogetherKey
    static let enableListenTogether = PrefKey<Bool>("enableListenTogether", .bool)
    /// ListenTogetherAutoApprovalKey
    static let listenTogetherAutoApproval = PrefKey<Bool>("listenTogetherAutoApproval", .bool)
    /// ListenTogetherAutoApproveSuggestionsKey
    static let listenTogetherAutoApproveSuggestions = PrefKey<Bool>("listenTogetherAutoApproveSuggestions", .bool)
    /// ListenTogetherSyncVolumeKey
    static let listenTogetherSyncVolume = PrefKey<Bool>("listenTogetherSyncVolume", .bool)
    /// ListenTogetherBlockedUsersKey
    static let listenTogetherBlockedUsers = PrefKey<String>("listenTogetherBlockedUsers", .string)
    /// ListenTogetherInTopBarKey
    static let listenTogetherInTopBar = PrefKey<Bool>("listenTogetherInTopBar", .bool)
    /// ListenTogetherSessionTokenKey
    static let listenTogetherSessionToken = PrefKey<String>("listenTogetherSessionToken", .string)
    /// ListenTogetherRoomCodeKey
    static let listenTogetherRoomCode = PrefKey<String>("listenTogetherRoomCode", .string)
    /// ListenTogetherUserIdKey
    static let listenTogetherUserId = PrefKey<String>("listenTogetherUserId", .string)
    /// ListenTogetherIsHostKey
    static let listenTogetherIsHost = PrefKey<Bool>("listenTogetherIsHost", .bool)
    /// ListenTogetherSessionTimestampKey
    static let listenTogetherSessionTimestamp = PrefKey<Int>("listenTogetherSessionTimestamp", .long)
    /// LastFMSessionKey
    static let lastfmSession = PrefKey<String>("lastfmSession", .string)
    /// LastFMUsernameKey
    static let lastfmUsername = PrefKey<String>("lastfmUsername", .string)
    /// EnableLastFMScrobblingKey
    static let lastfmScrobblingEnable = PrefKey<Bool>("lastfmScrobblingEnable", .bool)
    /// LastFMUseNowPlaying
    static let lastfmUseNowPlaying = PrefKey<Bool>("lastfmUseNowPlaying", .bool)
    /// LastFMUseSendLikes
    static let lastfmUseSendLikes = PrefKey<Bool>("lastfmUseSendLikes", .bool)
    /// ScrobbleDelayPercentKey
    static let scrobbleDelayPercent = PrefKey<Float>("scrobbleDelayPercent", .float)
    /// ScrobbleMinSongDurationKey
    static let scrobbleMinSongDuration = PrefKey<Int>("scrobbleMinSongDuration", .int)
    /// ScrobbleDelaySecondsKey
    static let scrobbleDelaySeconds = PrefKey<Int>("scrobbleDelaySeconds", .int)
    /// EnableSpotifyKey
    static let enableSpotify = PrefKey<Bool>("enableSpotify", .bool)
    /// UseSpotifySearchKey
    static let useSpotifySearch = PrefKey<Bool>("useSpotifySearch", .bool)
    /// UseSpotifyHomeKey
    static let useSpotifyHome = PrefKey<Bool>("useSpotifyHome", .bool)
    /// SpotifyHomeOnlyKey
    static let spotifyHomeOnly = PrefKey<Bool>("spotifyHomeOnly", .bool)
    /// SpotifyLooseMatchKey
    static let spotifyLooseMatch = PrefKey<Bool>("spotifyLooseMatch", .bool)
    /// SpotifyQobuzFallbackKey
    static let spotifyQobuzFallback = PrefKey<Bool>("spotifyQobuzFallback", .bool)
    /// SpotifySyncLikesKey
    static let spotifySyncLikes = PrefKey<Bool>("spotifySyncLikes", .bool)
    /// HideYtmLikedSongsKey
    static let hideYtmLikedSongs = PrefKey<Bool>("hideYtmLikedSongs", .bool)
    /// SpotifySpDcKey
    static let spotifySpDc = PrefKey<String>("spotifySpDc", .string)
    /// SpotifySpKeyKey
    static let spotifySpKey = PrefKey<String>("spotifySpKey", .string)
    /// SpotifyAccessTokenKey
    static let spotifyAccessToken = PrefKey<String>("spotifyAccessToken", .string)
    /// SpotifyTokenExpiryKey
    static let spotifyTokenExpiry = PrefKey<Int>("spotifyTokenExpiry", .long)
    /// SpotifyUsernameKey
    static let spotifyUsername = PrefKey<String>("spotifyUsername", .string)
    /// SpotifyUserIdKey
    static let spotifyUserId = PrefKey<String>("spotifyUserId", .string)
    /// MusicSourceKey
    static let musicSource = PrefKey<String>("musicSource", .string)
    /// YandexAccessTokenKey
    static let yandexAccessToken = PrefKey<String>("yandexAccessToken", .string)
    /// YandexUidKey
    static let yandexUid = PrefKey<String>("yandexUid", .string)
    /// YandexUsernameKey
    static let yandexUsername = PrefKey<String>("yandexUsername", .string)
    /// PrimaryMetadataSourceKey
    static let primaryMetadataSource = PrefKey<String>("primaryMetadataSource", .string)
    /// AudioSourceYouTubeKey
    static let audioSourceYouTube = PrefKey<Bool>("audioSourceYouTube", .bool)
    /// AudioSourceSoundCloudKey
    static let audioSourceSoundCloud = PrefKey<Bool>("audioSourceSoundCloud", .bool)
    /// AudioSourceVkKey
    static let audioSourceVk = PrefKey<Bool>("audioSourceVk", .bool)
    /// AudioSourceBandcampKey
    static let audioSourceBandcamp = PrefKey<Bool>("audioSourceBandcamp", .bool)
    /// AudioSourceAudiusKey
    static let audioSourceAudius = PrefKey<Bool>("audioSourceAudius", .bool)
    /// AudioSourceSoulseekKey
    static let audioSourceSoulseek = PrefKey<Bool>("audioSourceSoulseek", .bool)
    /// SoulseekUsernameKey
    static let soulseekUsername = PrefKey<String>("soulseekUsername", .string)
    /// SoulseekPasswordKey
    static let soulseekPassword = PrefKey<String>("soulseekPassword", .string)
    /// SoulseekWifiOnlyKey
    static let soulseekWifiOnly = PrefKey<Bool>("soulseekWifiOnly", .bool)
    /// AudioSourceOrderKey
    static let audioSourceOrder = PrefKey<String>("audioSourceOrder", .string)
    /// SourcePickModeKey
    static let sourcePickMode = PrefKey<String>("sourcePickMode", .string)
    /// AudioSourceLosslessKey
    static let audioSourceLossless = PrefKey<Bool>("audioSourceLossless", .bool)
    /// DownloadFormatKey
    static let downloadFormat = PrefKey<String>("downloadFormat", .string)
    /// VkAccessTokenKey
    static let vkAccessToken = PrefKey<String>("vkAccessToken", .string)
    /// VkUserIdKey
    static let vkUserId = PrefKey<String>("vkUserId", .string)
    /// SoundCloudClientIdKey
    static let soundCloudClientId = PrefKey<String>("soundCloudClientId", .string)
    /// EnableQobuzKey
    static let enableQobuz = PrefKey<Bool>("enableQobuz", .bool)
    /// QobuzAudioQualityKey
    static let qobuzAudioQuality = PrefKey<String>("qobuzAudioQuality", .string)
    /// QobuzBackendKey
    static let qobuzBackend = PrefKey<String>("qobuzBackend", .string)
    /// QobuzCountryKey
    static let qobuzCountry = PrefKey<String>("qobuzCountry", .string)
    /// QobuzMatchOverridesKey
    static let qobuzMatchOverrides = PrefKey<String>("qobuzMatchOverrides", .string)
    /// QobuzSquidEndpointKey
    static let qobuzSquidEndpoint = PrefKey<String>("qobuzSquidEndpoint", .string)
    /// QobuzKennyEndpointKey
    static let qobuzKennyEndpoint = PrefKey<String>("qobuzKennyEndpoint", .string)
    /// QobuzTryptEndpointKey
    static let qobuzTryptEndpoint = PrefKey<String>("qobuzTryptEndpoint", .string)
    /// QobuzJumoEndpointKey
    static let qobuzJumoEndpoint = PrefKey<String>("qobuzJumoEndpoint", .string)
    /// ChipSortTypeKey
    static let chipSortType = PrefKey<String>("chipSortType", .string)
    /// SongSortTypeKey
    static let songSortType = PrefKey<String>("songSortType", .string)
    /// SongSortDescendingKey
    static let songSortDescending = PrefKey<Bool>("songSortDescending", .bool)
    /// PlaylistSongSortTypeKey
    static let playlistSongSortType = PrefKey<String>("playlistSongSortType", .string)
    /// PlaylistSongSortDescendingKey
    static let playlistSongSortDescending = PrefKey<Bool>("playlistSongSortDescending", .bool)
    /// AutoPlaylistSongSortTypeKey
    static let autoPlaylistSongSortType = PrefKey<String>("autoPlaylistSongSortType", .string)
    /// AutoPlaylistSongSortDescendingKey
    static let autoPlaylistSongSortDescending = PrefKey<Bool>("autoPlaylistSongSortDescending", .bool)
    /// ArtistSortTypeKey
    static let artistSortType = PrefKey<String>("artistSortType", .string)
    /// ArtistSortDescendingKey
    static let artistSortDescending = PrefKey<Bool>("artistSortDescending", .bool)
    /// AlbumSortTypeKey
    static let albumSortType = PrefKey<String>("albumSortType", .string)
    /// AlbumSortDescendingKey
    static let albumSortDescending = PrefKey<Bool>("albumSortDescending", .bool)
    /// PlaylistSortTypeKey
    static let playlistSortType = PrefKey<String>("playlistSortType", .string)
    /// PlaylistSortDescendingKey
    static let playlistSortDescending = PrefKey<Bool>("playlistSortDescending", .bool)
    /// AddToPlaylistSortTypeKey
    static let addToPlaylistSortType = PrefKey<String>("addToPlaylistSortType", .string)
    /// AddToPlaylistSortDescendingKey
    static let addToPlaylistSortDescending = PrefKey<Bool>("addToPlaylistSortDescending", .bool)
    /// ArtistSongSortTypeKey
    static let artistSongSortType = PrefKey<String>("artistSongSortType", .string)
    /// ArtistSongSortDescendingKey
    static let artistSongSortDescending = PrefKey<Bool>("artistSongSortDescending", .bool)
    /// MixSortTypeKey
    static let mixSortType = PrefKey<String>("mixSortType", .string)
    /// SpotifyPlaylistSortTypeKey
    static let spotifyPlaylistSortType = PrefKey<String>("spotifyPlaylistSortType", .string)
    /// SpotifyPlaylistSortDescendingKey
    static let spotifyPlaylistSortDescending = PrefKey<Bool>("spotifyPlaylistSortDescending", .bool)
    /// SpotifyLikedSortTypeKey
    static let spotifyLikedSortType = PrefKey<String>("spotifyLikedSortType", .string)
    /// SpotifyLikedSortDescendingKey
    static let spotifyLikedSortDescending = PrefKey<Bool>("spotifyLikedSortDescending", .bool)
    /// SongFilterKey
    static let songFilter = PrefKey<String>("songFilter", .string)
    /// ArtistFilterKey
    static let artistFilter = PrefKey<String>("artistFilter", .string)
    /// AlbumFilterKey
    static let albumFilter = PrefKey<String>("albumFilter", .string)
    /// PodcastFilterKey
    static let podcastFilter = PrefKey<String>("podcastFilter", .string)
    /// LastLikeSongSyncKey
    static let lastLikeSongSync = PrefKey<Int>("last_like_song_sync", .long)
    /// LastLibSongSyncKey
    static let lastLibrarySongSync = PrefKey<Int>("last_library_song_sync", .long)
    /// LastAlbumSyncKey
    static let lastAlbumSync = PrefKey<Int>("last_album_sync", .long)
    /// LastArtistSyncKey
    static let lastArtistSync = PrefKey<Int>("last_artist_sync", .long)
    /// LastPlaylistSyncKey
    static let lastPlaylistSync = PrefKey<Int>("last_playlist_sync", .long)
    /// LastFullSyncKey
    static let lastFullSync = PrefKey<Int>("last_full_sync", .long)
    /// LastWeeklyMostPlaylistSyncKey
    static let lastWeeklyMostPlaylistSync = PrefKey<Int>("last_weekly_most_playlist_sync", .long)
    /// LastMonthlyMostPlaylistSyncKey
    static let lastMonthlyMostPlaylistSync = PrefKey<Int>("last_monthly_most_playlist_sync", .long)
    /// ArtistViewTypeKey
    static let artistViewType = PrefKey<String>("artistViewType", .string)
    /// AlbumViewTypeKey
    static let albumViewType = PrefKey<String>("albumViewType", .string)
    /// PlaylistViewTypeKey
    static let playlistViewType = PrefKey<String>("playlistViewType", .string)
    /// PlaylistEditLockKey
    static let playlistEditLock = PrefKey<Bool>("playlistEditLock", .bool)
    /// QuickPicksKey
    static let discover = PrefKey<String>("discover", .string)
    /// PreferredLyricsProviderKey
    static let lyricsProvider = PrefKey<String>("lyricsProvider", .string)
    /// LyricsProviderOrderKey
    static let lyricsProviderOrder = PrefKey<String>("lyricsProviderOrder", .string)
    /// SimpMusicMigrationDoneKey
    static let simpMusicMigrationDone = PrefKey<Bool>("simpMusicMigrationDone", .bool)
    /// QueueEditLockKey
    static let queueEditLock = PrefKey<Bool>("queueEditLock", .bool)
    /// ShowWrappedCardKey
    static let showWrappedCard = PrefKey<Bool>("show_wrapped_card", .bool)
    /// WrappedSeenKey
    static let wrappedSeen = PrefKey<Bool>("wrapped_seen", .bool)
    /// LastSeenVersionKey
    static let lastSeenVersion = PrefKey<String>("lastSeenVersion", .string)
    /// ShowRecognizeButtonKey
    static let showRecognizeButton = PrefKey<Bool>("showRecognizeButton", .bool)
    /// ShowPlayRandomButtonKey
    static let showPlayRandomButton = PrefKey<Bool>("showPlayRandomButton", .bool)
    /// RandomizeHomeOrderKey
    static let randomizeHomeOrder = PrefKey<Bool>("randomizeHomeOrder", .bool)
    /// ShowLikedPlaylistKey
    static let showLikedPlaylist = PrefKey<Bool>("show_liked_playlist", .bool)
    /// ShowDownloadedPlaylistKey
    static let showDownloadedPlaylist = PrefKey<Bool>("show_downloaded_playlist", .bool)
    /// ShowTopPlaylistKey
    static let showTopPlaylist = PrefKey<Bool>("show_top_playlist", .bool)
    /// ShowCachedPlaylistKey
    static let showCachedPlaylist = PrefKey<Bool>("show_cached_playlist", .bool)
    /// ShowUploadedPlaylistKey
    static let showUploadedPlaylist = PrefKey<Bool>("show_uploaded_playlist", .bool)
    /// TopSize
    static let topSize = PrefKey<String>("topSize", .string)
    /// HistoryDuration
    static let historyDuration = PrefKey<Float>("historyDuration", .float)
    /// PlayerButtonsStyleKey
    static let playerButtonsStyle = PrefKey<String>("player_buttons_style", .string)
    /// PlayerBackgroundStyleKey
    static let playerBackgroundStyle = PrefKey<String>("playerBackgroundStyle", .string)
    /// ShowLyricsKey
    static let showLyrics = PrefKey<Bool>("showLyrics", .bool)
    /// LyricsTextPositionKey
    static let lyricsTextPosition = PrefKey<String>("lyricsTextPosition", .string)
    /// LyricsClickKey
    static let lyricsClick = PrefKey<Bool>("lyricsClick", .bool)
    /// LyricsScrollKey
    static let lyricsScrollKey = PrefKey<Bool>("lyricsScrollKey", .bool)
    /// HideStatusBarOnFullscreenKey
    static let hideStatusBarOnFullscreen = PrefKey<Bool>("hideStatusBarOnFullscreen", .bool)
    /// LyricsRomanizeAsMainKey
    static let lyricsRomanizeAsMain = PrefKey<Bool>("lyricsRomanizeAsMain", .bool)
    /// LyricsRomanizeCyrillicByLineKey
    static let lyricsRomanizeCyrillicByLine = PrefKey<Bool>("lyricsRomanizeCyrillicByLine", .bool)
    /// OpenRouterApiKey
    static let openRouterApiKey = PrefKey<String>("openRouterApiKey", .string)
    /// AiProviderKey
    static let aiProvider = PrefKey<String>("aiProvider", .string)
    /// OpenRouterBaseUrlKey
    static let openRouterBaseUrl = PrefKey<String>("openRouterBaseUrl", .string)
    /// OpenRouterModelKey
    static let openRouterModel = PrefKey<String>("openRouterModel", .string)
    /// TranslateModeKey
    static let translateMode = PrefKey<String>("translateMode", .string)
    /// TranslateLanguageKey
    static let translateLanguage = PrefKey<String>("translateLanguage", .string)
    /// DeeplApiKey
    static let deeplApiKey = PrefKey<String>("deeplApiKey", .string)
    /// DeeplFormalityKey
    static let deeplFormality = PrefKey<String>("deeplFormality", .string)
    /// AiSystemPromptKey
    static let aiSystemPrompt = PrefKey<String>("aiSystemPrompt", .string)
    /// LyricsGlowEffectKey
    static let lyricsGlowEffect = PrefKey<Bool>("lyricsGlowEffect", .bool)
    /// LyricsRomanizeList
    static let lyricsRomanizeList = PrefKey<String>("lyricsRomanizeList", .string)
    /// LyricsAnimationStyleKey
    static let lyricsAnimationStyle = PrefKey<String>("lyricsAnimationStyle", .string)
    /// LyricsTextSizeKey
    static let lyricsTextSize = PrefKey<Float>("lyricsTextSize", .float)
    /// LyricsLineSpacingKey
    static let lyricsLineSpacing = PrefKey<Float>("lyricsLineSpacing", .float)
    /// RespectAgentPositioningKey
    static let respectAgentPositioning = PrefKey<Bool>("respectAgentPositioning", .bool)
    /// ShowIntervalIndicatorKey
    static let showIntervalIndicator = PrefKey<Bool>("showIntervalIndicator", .bool)
    /// ExperimentalLyricsKey
    static let experimentalLyrics = PrefKey<Bool>("experimentalLyrics", .bool)
    /// PlayerVolumeKey
    static let playerVolume = PrefKey<Float>("playerVolume", .float)
    /// SleepTimerDefaultKey
    static let sleepTimerDefault = PrefKey<Float>("sleepTimerDefault", .float)
    /// SleepTimerStopAfterCurrentSongKey
    static let sleepTimerStopAfterCurrentSong = PrefKey<Bool>("sleepTimerStopAfterCurrentSong", .bool)
    /// SleepTimerFadeOutKey
    static let sleepTimerFadeOut = PrefKey<Bool>("sleepTimerFadeOut", .bool)
    /// RepeatModeKey
    static let repeatMode = PrefKey<Int>("repeatMode", .int)
    /// SearchSourceKey
    static let searchSource = PrefKey<String>("searchSource", .string)
    /// SwipeThumbnailKey
    static let swipeThumbnail = PrefKey<Bool>("swipeThumbnail", .bool)
    /// SwipeSensitivityKey
    static let swipeSensitivity = PrefKey<Float>("swipeSensitivity", .float)
    /// SleepTimerEnabledKey
    static let sleepTimerEnabled = PrefKey<Bool>("sleepTimerEnabled", .bool)
    /// SleepTimerRepeatKey
    static let sleepTimerRepeat = PrefKey<String>("sleepTimerRepeat", .string)
    /// SleepTimerStartTimeKey
    static let sleepTimerStartTime = PrefKey<String>("sleepTimerStartTime", .string)
    /// SleepTimerEndTimeKey
    static let sleepTimerEndTime = PrefKey<String>("sleepTimerEndTime", .string)
    /// SleepTimerCustomDaysKey
    static let sleepTimerCustomDays = PrefKey<String>("sleepTimerCustomDays", .string)
    /// SleepTimerDayTimesKey
    static let sleepTimerDayTimes = PrefKey<String>("sleepTimerDayTimes", .string)
    /// ExperimentalSearchEnabledKey
    static let experimentalSearchEnabled = PrefKey<Bool>("experimentalSearchEnabled", .bool)
    /// ExperimentalSearchSourceKey
    static let experimentalSearchSource = PrefKey<String>("experimentalSearchSource", .string)
    /// StereoBalanceKey
    static let stereoBalance = PrefKey<Float>("stereoBalance", .float)
    /// VkLikesToAccountKey
    static let vkLikesToAccount = PrefKey<Bool>("vkLikesToAccount", .bool)
    /// ExperimentalSearchAckKey
    static let experimentalSearchAcknowledged = PrefKey<Bool>("experimentalSearchAcknowledged", .bool)
    /// VisitorDataKey
    static let visitorData = PrefKey<String>("visitorData", .string)
    /// DataSyncIdKey
    static let dataSyncId = PrefKey<String>("dataSyncId", .string)
    /// AndroidAutoYouTubePlaylistsKey
    static let androidAutoYoutubePlaylists = PrefKey<Bool>("androidAutoYoutubePlaylists", .bool)
    /// AndroidAutoSectionsOrderKey
    static let androidAutoSectionsOrder = PrefKey<String>("androidAutoSectionsOrder", .string)
    /// AndroidAutoTargetPlaylistKey
    static let androidAutoTargetPlaylist = PrefKey<String>("androidAutoTargetPlaylist", .string)
    /// InnerTubeCookieKey
    static let innerTubeCookie = PrefKey<String>("innerTubeCookie", .string)
    /// AccountNameKey
    static let accountName = PrefKey<String>("accountName", .string)
    /// AccountEmailKey
    static let accountEmail = PrefKey<String>("accountEmail", .string)
    /// AccountChannelHandleKey
    static let accountChannelHandle = PrefKey<String>("accountChannelHandle", .string)
    /// UseLoginForBrowse
    static let useLoginForBrowse = PrefKey<Bool>("useLoginForBrowse", .bool)
    /// SponsorBlockEnabledKey
    static let sponsorBlockEnabled = PrefKey<Bool>("sponsorBlockEnabled", .bool)
    /// SponsorBlockCategoriesKey
    static let sponsorBlockCategories = PrefKey<String>("sponsorBlockCategories", .string)
    /// SponsorBlockShowToastKey
    static let sponsorBlockShowToast = PrefKey<Bool>("sponsorBlockShowToast", .bool)
    /// (extra)
    static let bitratesBySize220 = PrefKey<Bool>("bitratesBySize220", .bool)
    /// (extra)
    static let sourcesRecheck220c = PrefKey<Bool>("sourcesRecheck220c", .bool)
    /// (extra)
    static let qualityModes220 = PrefKey<Bool>("qualityModes220", .bool)
    /// (extra)
    static let spotifyProfileTracksJson = PrefKey<String>("spotify_profile_tracks_json", .string)
    /// (extra)
    static let spotifyProfileArtistsJson = PrefKey<String>("spotify_profile_artists_json", .string)
    /// (extra)
    static let spotifyProfileCacheTs = PrefKey<Int>("spotify_profile_cache_ts", .long)
    /// (extra)
    static let spotifyProfileHadRest = PrefKey<Bool>("spotify_profile_had_rest", .bool)
    /// (extra)
    static let spotifyFollowedArtistsJson = PrefKey<String>("spotify_followed_artists_json", .string)
    /// (extra)
    static let spotifyFollowedArtistsTs = PrefKey<Int>("spotify_followed_artists_ts", .long)
    /// (extra)
    static let spotifyRelatedArtistNamesJson = PrefKey<String>("spotify_related_artist_names_json", .string)
    /// (extra)
    static let spotifyRelatedArtistNamesTs = PrefKey<Int>("spotify_related_artist_names_ts", .long)
    /// (extra)
    static let spotifyCachedPlaylistsJson = PrefKey<String>("spotify_cached_playlists_json", .string)
    /// (extra)
    static let spotifyLibraryGrid = PrefKey<Bool>("spotify_library_grid", .bool)
    /// (extra)
    static let reviewsSort = PrefKey<String>("reviews_sort", .string)
    /// (extra)
    static let reviewsDesc = PrefKey<Bool>("reviews_desc", .bool)
    /// (extra)
    static let remoteConfigUrl = PrefKey<String>("remoteConfigUrl", .string)
    /// (extra)
    static let remoteConfigCache = PrefKey<String>("remoteConfigCache", .string)
    /// (extra)
    static let spotifyGqlHashesJson = PrefKey<String>("spotify_gql_hashes_json", .string)
    /// (extra)
    static let spotifyGqlHashesLastFetch = PrefKey<Int>("spotify_gql_hashes_last_fetch", .long)

    /// Тип каждого известного ключа — для записи в protobuf при создании копии.
    static let kinds: [String: PrefKind] = [
        "enableDynamicIcon": .bool,
        "enableHighRefreshRate": .bool,
        "dynamicTheme": .bool,
        "selectedThemeColor": .int,
        "darkMode": .string,
        "appThemePreset": .string,
        "themeAnimations": .bool,
        "appIcon": .string,
        "pureBlack": .bool,
        "pureBlackMiniPlayer": .bool,
        "miniPlayerOutline": .bool,
        "miniPlayerBackgroundStyle": .string,
        "density_scale_factor": .float,
        "custom_density_scale_value": .float,
        "defaultOpenTab": .string,
        "slimNavBar": .bool,
        "gridItemSize": .string,
        "sliderStyle": .string,
        "squigglySlider": .bool,
        "SwipeToSong": .bool,
        "SwipeToRemoveSong": .bool,
        "useNewPlayerDesign": .bool,
        "useNewMiniPlayerDesign": .bool,
        "hidePlayerThumbnail": .bool,
        "cropAlbumArt": .bool,
        "seekExtraSeconds": .bool,
        "pauseOnMute": .bool,
        "resumeOnBluetoothConnect": .bool,
        "keepScreenOn": .bool,
        "alarmEnabled": .bool,
        "alarmHour": .int,
        "alarmMinute": .int,
        "alarmPlaylistId": .string,
        "alarmRandomSong": .bool,
        "alarmNextTriggerAt": .long,
        "alarmEntries": .string,
        "developerMode": .bool,
        "appLanguage": .string,
        "contentLanguage": .string,
        "contentCountry": .string,
        "enableKugou": .bool,
        "enableLrclib": .bool,
        "enableBetterLyrics": .bool,
        "enablePaxsenix": .bool,
        "enableLyricsPlus": .bool,
        "enableMusixmatch": .bool,
        "hideExplicit": .bool,
        "hideVideoSongs": .bool,
        "hideYoutubeShorts": .bool,
        "showArtistDescription": .bool,
        "showArtistSubscriberCount": .bool,
        "showMonthlyListeners": .bool,
        "proxyEnabled": .bool,
        "proxyUrl": .string,
        "proxyType": .string,
        "proxyUsername": .string,
        "proxyPassword": .string,
        "ytmSync": .bool,
        "selectedYtmPlaylists": .string,
        "checkForUpdates": .bool,
        "updateNotifications": .bool,
        "lastUpdateCheckTime": .long,
        "audioQuality": .string,
        "enableOffload": .bool,
        "varispeed": .bool,
        "persistentQueue": .bool,
        "persistentShuffleAcrossQueues": .bool,
        "rememberShuffleAndRepeat": .bool,
        "shuffleMode": .bool,
        "skipSilence": .bool,
        "skipSilenceInstant": .bool,
        "audioNormalization": .bool,
        "audioFocusEnabled": .bool,
        "autoLoadMore": .bool,
        "disableLoadMoreWhenRepeatAll": .bool,
        "autoDownloadOnLike": .bool,
        "similarContent": .bool,
        "autoSkipNextOnError": .bool,
        "stopMusicOnTaskClear": .bool,
        "shufflePlaylistFirst": .bool,
        "preventDuplicateTracksInQueue": .bool,
        "crossfadeEnabled": .bool,
        "crossfadeDurationFloat": .float,
        "crossfadeGapless": .bool,
        "maxImageCacheSize": .int,
        "maxSongCacheSize": .int,
        "enableSongCache": .bool,
        "preCacheTracks": .int,
        "preCacheOnlyWifi": .bool,
        "downloadFolderUri": .string,
        "exportedSongIds": .stringSet,
        "exportedSongUris": .stringSet,
        "pendingExportSongIds": .stringSet,
        "exportFolderHints": .stringSet,
        "pauseListenHistory": .bool,
        "pauseSearchHistory": .bool,
        "disableScreenshot": .bool,
        "crashReportingEnabled": .bool,
        "discordToken": .string,
        "discordInfoDismissed": .bool,
        "discordUsername": .string,
        "discordName": .string,
        "discordRPCEnable": .bool,
        "discordUseDetails": .bool,
        "discordAvatar": .string,
        "discordStatus": .string,
        "discordButton1Text": .string,
        "discordButton1Visible": .bool,
        "discordButton1Url": .string,
        "discordButton2Text": .string,
        "discordButton2Visible": .bool,
        "discordButton2Url": .string,
        "discordActivityType": .string,
        "discordActivityName": .string,
        "discordAdvancedMode": .bool,
        "enableGoogleCast": .bool,
        "listenTogetherServerUrl": .string,
        "listenTogetherUsername": .string,
        "enableListenTogether": .bool,
        "listenTogetherAutoApproval": .bool,
        "listenTogetherAutoApproveSuggestions": .bool,
        "listenTogetherSyncVolume": .bool,
        "listenTogetherBlockedUsers": .string,
        "listenTogetherInTopBar": .bool,
        "listenTogetherSessionToken": .string,
        "listenTogetherRoomCode": .string,
        "listenTogetherUserId": .string,
        "listenTogetherIsHost": .bool,
        "listenTogetherSessionTimestamp": .long,
        "lastfmSession": .string,
        "lastfmUsername": .string,
        "lastfmScrobblingEnable": .bool,
        "lastfmUseNowPlaying": .bool,
        "lastfmUseSendLikes": .bool,
        "scrobbleDelayPercent": .float,
        "scrobbleMinSongDuration": .int,
        "scrobbleDelaySeconds": .int,
        "enableSpotify": .bool,
        "useSpotifySearch": .bool,
        "useSpotifyHome": .bool,
        "spotifyHomeOnly": .bool,
        "spotifyLooseMatch": .bool,
        "spotifyQobuzFallback": .bool,
        "spotifySyncLikes": .bool,
        "hideYtmLikedSongs": .bool,
        "spotifySpDc": .string,
        "spotifySpKey": .string,
        "spotifyAccessToken": .string,
        "spotifyTokenExpiry": .long,
        "spotifyUsername": .string,
        "spotifyUserId": .string,
        "musicSource": .string,
        "yandexAccessToken": .string,
        "yandexUid": .string,
        "yandexUsername": .string,
        "primaryMetadataSource": .string,
        "audioSourceYouTube": .bool,
        "audioSourceSoundCloud": .bool,
        "audioSourceVk": .bool,
        "audioSourceBandcamp": .bool,
        "audioSourceAudius": .bool,
        "audioSourceSoulseek": .bool,
        "soulseekUsername": .string,
        "soulseekPassword": .string,
        "soulseekWifiOnly": .bool,
        "audioSourceOrder": .string,
        "sourcePickMode": .string,
        "audioSourceLossless": .bool,
        "downloadFormat": .string,
        "vkAccessToken": .string,
        "vkUserId": .string,
        "soundCloudClientId": .string,
        "enableQobuz": .bool,
        "qobuzAudioQuality": .string,
        "qobuzBackend": .string,
        "qobuzCountry": .string,
        "qobuzMatchOverrides": .string,
        "qobuzSquidEndpoint": .string,
        "qobuzKennyEndpoint": .string,
        "qobuzTryptEndpoint": .string,
        "qobuzJumoEndpoint": .string,
        "chipSortType": .string,
        "songSortType": .string,
        "songSortDescending": .bool,
        "playlistSongSortType": .string,
        "playlistSongSortDescending": .bool,
        "autoPlaylistSongSortType": .string,
        "autoPlaylistSongSortDescending": .bool,
        "artistSortType": .string,
        "artistSortDescending": .bool,
        "albumSortType": .string,
        "albumSortDescending": .bool,
        "playlistSortType": .string,
        "playlistSortDescending": .bool,
        "addToPlaylistSortType": .string,
        "addToPlaylistSortDescending": .bool,
        "artistSongSortType": .string,
        "artistSongSortDescending": .bool,
        "mixSortType": .string,
        "spotifyPlaylistSortType": .string,
        "spotifyPlaylistSortDescending": .bool,
        "spotifyLikedSortType": .string,
        "spotifyLikedSortDescending": .bool,
        "songFilter": .string,
        "artistFilter": .string,
        "albumFilter": .string,
        "podcastFilter": .string,
        "last_like_song_sync": .long,
        "last_library_song_sync": .long,
        "last_album_sync": .long,
        "last_artist_sync": .long,
        "last_playlist_sync": .long,
        "last_full_sync": .long,
        "last_weekly_most_playlist_sync": .long,
        "last_monthly_most_playlist_sync": .long,
        "artistViewType": .string,
        "albumViewType": .string,
        "playlistViewType": .string,
        "playlistEditLock": .bool,
        "discover": .string,
        "lyricsProvider": .string,
        "lyricsProviderOrder": .string,
        "simpMusicMigrationDone": .bool,
        "queueEditLock": .bool,
        "show_wrapped_card": .bool,
        "wrapped_seen": .bool,
        "lastSeenVersion": .string,
        "showRecognizeButton": .bool,
        "showPlayRandomButton": .bool,
        "randomizeHomeOrder": .bool,
        "show_liked_playlist": .bool,
        "show_downloaded_playlist": .bool,
        "show_top_playlist": .bool,
        "show_cached_playlist": .bool,
        "show_uploaded_playlist": .bool,
        "topSize": .string,
        "historyDuration": .float,
        "player_buttons_style": .string,
        "playerBackgroundStyle": .string,
        "showLyrics": .bool,
        "lyricsTextPosition": .string,
        "lyricsClick": .bool,
        "lyricsScrollKey": .bool,
        "hideStatusBarOnFullscreen": .bool,
        "lyricsRomanizeAsMain": .bool,
        "lyricsRomanizeCyrillicByLine": .bool,
        "openRouterApiKey": .string,
        "aiProvider": .string,
        "openRouterBaseUrl": .string,
        "openRouterModel": .string,
        "translateMode": .string,
        "translateLanguage": .string,
        "deeplApiKey": .string,
        "deeplFormality": .string,
        "aiSystemPrompt": .string,
        "lyricsGlowEffect": .bool,
        "lyricsRomanizeList": .string,
        "lyricsAnimationStyle": .string,
        "lyricsTextSize": .float,
        "lyricsLineSpacing": .float,
        "respectAgentPositioning": .bool,
        "showIntervalIndicator": .bool,
        "experimentalLyrics": .bool,
        "playerVolume": .float,
        "sleepTimerDefault": .float,
        "sleepTimerStopAfterCurrentSong": .bool,
        "sleepTimerFadeOut": .bool,
        "repeatMode": .int,
        "searchSource": .string,
        "swipeThumbnail": .bool,
        "swipeSensitivity": .float,
        "sleepTimerEnabled": .bool,
        "sleepTimerRepeat": .string,
        "sleepTimerStartTime": .string,
        "sleepTimerEndTime": .string,
        "sleepTimerCustomDays": .string,
        "sleepTimerDayTimes": .string,
        "experimentalSearchEnabled": .bool,
        "experimentalSearchSource": .string,
        "stereoBalance": .float,
        "vkLikesToAccount": .bool,
        "experimentalSearchAcknowledged": .bool,
        "visitorData": .string,
        "dataSyncId": .string,
        "androidAutoYoutubePlaylists": .bool,
        "androidAutoSectionsOrder": .string,
        "androidAutoTargetPlaylist": .string,
        "innerTubeCookie": .string,
        "accountName": .string,
        "accountEmail": .string,
        "accountChannelHandle": .string,
        "useLoginForBrowse": .bool,
        "sponsorBlockEnabled": .bool,
        "sponsorBlockCategories": .string,
        "sponsorBlockShowToast": .bool,
        "bitratesBySize220": .bool,
        "sourcesRecheck220c": .bool,
        "qualityModes220": .bool,
        "spotify_profile_tracks_json": .string,
        "spotify_profile_artists_json": .string,
        "spotify_profile_cache_ts": .long,
        "spotify_profile_had_rest": .bool,
        "spotify_followed_artists_json": .string,
        "spotify_followed_artists_ts": .long,
        "spotify_related_artist_names_json": .string,
        "spotify_related_artist_names_ts": .long,
        "spotify_cached_playlists_json": .string,
        "spotify_library_grid": .bool,
        "reviews_sort": .string,
        "reviews_desc": .bool,
        "remoteConfigUrl": .string,
        "remoteConfigCache": .string,
        "spotify_gql_hashes_json": .string,
        "spotify_gql_hashes_last_fetch": .long,
    ]
}
