// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get updateTitle => 'Update available';

  @override
  String updateVersion(String version) {
    return 'Version $version';
  }

  @override
  String get updateInstall => 'Update';

  @override
  String get updateSkip => 'Skip this version';

  @override
  String updateDownloading(int percent) {
    return 'Downloading… $percent%';
  }

  @override
  String get updateFailed => 'Could not update. Try again.';

  @override
  String get updateCheck => 'Check for updates';

  @override
  String get updateLatest => 'You have the latest version';

  @override
  String get loginTitle => 'Connect to Apertono';

  @override
  String ratingStar(int n) {
    return '$n of 5';
  }

  @override
  String get ratingDislike => 'Dislike';

  @override
  String get ratingFailed => 'Couldn\'t save the rating';

  @override
  String get playerRate => 'Rate';

  @override
  String get playerLyrics => 'Lyrics';

  @override
  String get playerHeartHint =>
      'Hold the heart to rate the song or mark it as disliked';

  @override
  String get libraryRated => 'Rated';

  @override
  String ratedFrom(int n) {
    return '$n and up';
  }

  @override
  String get ratedEmpty => 'No rated songs yet';

  @override
  String get dislikedEmpty => 'No disliked songs';

  @override
  String get ratedFailed => 'Couldn\'t load the list';

  @override
  String get ratedRetry => 'Try again';

  @override
  String get loginSessionExpired => 'Session expired. Sign in again.';

  @override
  String get loginServerAddress => 'Server address';

  @override
  String get loginAddressInvalid => 'Use HTTPS or a home-network HTTP address.';

  @override
  String get loginAddressUnsupported => 'This server is not supported';

  @override
  String get loginAddressUnreachable =>
      'Cannot reach the server at this address';

  @override
  String get loginAddressExample => 'e.g. 192.168.1.20:8088';

  @override
  String loginConnectVia(String address) {
    return 'Will connect to $address';
  }

  @override
  String get loginChangeServer => 'Another server';

  @override
  String get loginNext => 'Next';

  @override
  String get historyPauseTitle => 'Don’t record history';

  @override
  String get historyPauseHint => 'For an hour, till tomorrow or indefinitely';

  @override
  String get historyPauseForHour => 'For an hour';

  @override
  String get historyPauseTillTomorrow => 'Till tomorrow';

  @override
  String get historyPauseForever => 'Until I turn it back on';

  @override
  String get historyPauseForeverOn => 'Until you turn it back on';

  @override
  String historyPauseUntil(String time) {
    return 'Until $time';
  }

  @override
  String get historyClear => 'Clear history';

  @override
  String get historyClearQuestion =>
      'Erase all listening history? This can’t be undone';

  @override
  String get historyClearConfirm => 'Erase';

  @override
  String get historyClearCancel => 'Cancel';

  @override
  String get historyError =>
      'That didn’t work. Check your connection and try again';

  @override
  String get historyRemoved => 'Removed from history';

  @override
  String get historyRemove => 'Remove from history';

  @override
  String get historyUndo => 'Undo';

  @override
  String get historyRemoveFailed => 'Couldn’t remove from history';

  @override
  String get loginUsername => 'Username';

  @override
  String get loginPassword => 'Password';

  @override
  String get prefetchTitle => 'Preload the next song';

  @override
  String get prefetchAlways => 'Always';

  @override
  String get prefetchWifiOnly => 'Wi-Fi only';

  @override
  String get prefetchNever => 'Never';

  @override
  String get prefetchNeverHint =>
      'A short pause between songs; saves mobile data';

  @override
  String get qualityTitle => 'Sound quality';

  @override
  String get qualityAuto => 'Auto';

  @override
  String get qualityAutoHint => 'Original on Wi-Fi, data saver on mobile data';

  @override
  String get qualityEconomy => 'Always data saver';

  @override
  String get qualityEconomyHint => 'Less data on any network';

  @override
  String get qualityLossless => 'Lossless only';

  @override
  String get qualityLosslessHint =>
      'FLAC when available. Otherwise plays what there is';

  @override
  String get loudnessTitle => 'Even loudness';

  @override
  String get loudnessHint => 'Quieter loud tracks';

  @override
  String formatBadgeSpoken(String format) {
    return 'Format: $format';
  }

  @override
  String get loginSignIn => 'Sign in';

  @override
  String get loginErrorTimeout => 'Server timed out';

  @override
  String get scrobbleWhy =>
      'This is optional. ListenBrainz and Last.fm are free sites that keep your listening statistics: what you played and how much. The history stays yours even if you change players. Connect your profile and the app will send the songs you play there.';

  @override
  String get scrobbleWhyLbOnly =>
      'This is optional. ListenBrainz is a free site that keeps your listening statistics: what you played and how much. The history stays yours even if you change players. Connect your profile and the app will send the songs you play there.';

  @override
  String get scrobbleStateOff => 'Not connected';

  @override
  String get scrobbleStateOn => 'Connected';

  @override
  String get scrobbleStateBadToken =>
      'The service rejected the key. Connect again.';

  @override
  String get scrobbleStatePending => 'Waiting for your approval';

  @override
  String get scrobbleTokenLabel => 'ListenBrainz token';

  @override
  String get scrobbleLbWhere => 'Where to get the token';

  @override
  String get scrobbleConnect => 'Connect';

  @override
  String get scrobbleDisconnect => 'Disconnect';

  @override
  String get scrobbleLastfmAllow => 'Allow in Last.fm';

  @override
  String get scrobbleLastfmCheck => 'Check approval';

  @override
  String get scrobbleLastfmCancel => 'Cancel';

  @override
  String get scrobbleLoadFailed => 'Failed to load settings';

  @override
  String get scrobbleRetry => 'Retry';

  @override
  String get scrobbleErrorTokenShape =>
      'This does not look like a token: 8 to 200 characters, no spaces';

  @override
  String get scrobbleErrorSave => 'Could not save. Try again.';

  @override
  String get scrobbleErrorLastfmStart => 'Last.fm did not answer. Try later.';

  @override
  String get scrobbleErrorLastfmNotYet =>
      'Not approved yet. Approve on the Last.fm page and check again.';

  @override
  String get scrobbleErrorLastfmExpired =>
      'The approval timed out. Start again.';

  @override
  String get scrobbleHint =>
      'Listens go only to connected services. While “Do not record” is on, nothing is sent.';

  @override
  String get loginErrorUnauthorized => 'Incorrect username or password';

  @override
  String get loginErrorBadCertificate => 'Invalid server certificate';

  @override
  String get loginErrorNetwork => 'Cannot connect to server';

  @override
  String get searchFailureNoAccess =>
      'No access: the build key does not match the server';

  @override
  String get searchFailureCatalogDown =>
      'The catalog is not responding — try again in a minute';

  @override
  String get searchFailureTooMany => 'Too many requests — wait and try again';

  @override
  String get searchFailureNoAnswer =>
      'The server did not respond — check your connection';

  @override
  String get searchRecent => 'Recent searches';

  @override
  String get searchClear => 'Clear';

  @override
  String get searchHeard => 'Recently played';

  @override
  String get searchArtistLabel => 'Artist';

  @override
  String get searchTracks => 'Tracks';

  @override
  String get searchTitle => 'Search';

  @override
  String get searchHint => 'Artist or song';

  @override
  String get searchEmpty => 'Nothing found';

  @override
  String get catalogKindLive => 'live';

  @override
  String get catalogKindCompilation => 'compilation';

  @override
  String get catalogKindSingle => 'single';

  @override
  String get catalogKindAlbum => 'album';

  @override
  String get catalogArtistOne => 'artist';

  @override
  String get catalogArtistFew => 'artists';

  @override
  String get catalogArtistMany => 'artists';

  @override
  String get catalogNoGenres => 'No genres yet';

  @override
  String get catalogBrowseTitle => 'Browse';

  @override
  String get catalogAllGenres => 'All genres';

  @override
  String get catalogNoArtists => 'No artists';

  @override
  String get catalogArtistNotFound => 'Artist not in the catalog';

  @override
  String get catalogAlbums => 'Albums';

  @override
  String get catalogEpAndSingles => 'EPs and singles';

  @override
  String get catalogLiveAndCompilations => 'Live and compilations';

  @override
  String get catalogListen => 'Listen';

  @override
  String get catalogPopular => 'Popular';

  @override
  String get catalogAllPopular => 'All popular';

  @override
  String get catalogAllAlbums => 'All albums';

  @override
  String get catalogNoAlbums => 'No albums in the catalog';

  @override
  String get catalogSimilarArtists => 'Similar artists';

  @override
  String get catalogAboutArtist => 'About the artist';

  @override
  String get catalogFollowing => 'Following';

  @override
  String get catalogFollow => 'Follow';

  @override
  String catalogPhotoCredit(String credit) {
    return 'photo: $credit';
  }

  @override
  String get catalogCollapse => 'Collapse';

  @override
  String get catalogExpand => 'Expand';

  @override
  String get catalogAlbumNotFound => 'Album not found';

  @override
  String get catalogPlayAlbum => 'Play album';

  @override
  String get catalogOtherEditions => 'Other editions';

  @override
  String get catalogArtistNotFoundSongs => 'Artist not found';

  @override
  String get homeTitle => 'Home';

  @override
  String get homeFavorites => 'Favorite songs';

  @override
  String get homeEmpty => 'Nothing yet';

  @override
  String get homeTrackOne => 'track';

  @override
  String get homeTrackFew => 'tracks';

  @override
  String get homeTrackMany => 'tracks';

  @override
  String get homePlaylists => 'Playlists';

  @override
  String get homePlaylistOne => 'playlist';

  @override
  String get homePlaylistFew => 'playlists';

  @override
  String get homePlaylistMany => 'playlists';

  @override
  String get partsNotFound => 'Not found';

  @override
  String get partsServerUnavailable => 'Server unavailable';

  @override
  String get partsTooMany => 'Too many requests — wait and try again';

  @override
  String get partsNoAnswer => 'The server did not respond';

  @override
  String get partsNoAccess =>
      'No access: the build key does not match the server';

  @override
  String get partsConflict => 'The playlist changed — showing the current one';

  @override
  String get partsDownloads => 'Downloads';

  @override
  String get partsRetry => 'Retry';

  @override
  String get partsReportSend => 'Send report';

  @override
  String get partsReportSent => 'Report sent';

  @override
  String get partsReportOff => 'Reports are disabled on the server';

  @override
  String get partsReportFailed => 'Could not send';

  @override
  String get partsPause => 'Pause';

  @override
  String get partsStopLoading => 'Stop loading';

  @override
  String get partsPlay => 'Play';

  @override
  String partsTrackMissing(String artist) {
    return '$artist · not found';
  }

  @override
  String get partsMore => 'More';

  @override
  String get partsPlayNext => 'Play next';

  @override
  String get partsWillPlayNext => 'Plays next';

  @override
  String get partsQueueEnd => 'Add to queue';

  @override
  String get partsOpenArtist => 'Go to artist';

  @override
  String get partsOpenAlbum => 'Go to album';

  @override
  String get partsDownload => 'Download';

  @override
  String get partsDeleteFromPhone => 'Delete from phone';

  @override
  String get partsAddToPlaylist => 'Add to playlist';

  @override
  String get partsRemoveFromPlaylist => 'Remove from playlist';

  @override
  String get partsRemoveFromFavorites => 'Remove from favorites';

  @override
  String get partsAddToFavorites => 'Add to favorites';

  @override
  String get partsPlaylistGone => 'The playlist is gone';

  @override
  String get partsAlbumGone => 'Album not found';

  @override
  String get partsName => 'Name';

  @override
  String get partsCancel => 'Cancel';

  @override
  String partsDuplicatesTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs are already in the playlist',
      one: '$count song is already in the playlist',
    );
    return '$_temp0';
  }

  @override
  String get partsDuplicatesAddAll => 'Add all';

  @override
  String get partsDuplicatesOnlyNew => 'Only new';

  @override
  String get partsSave => 'Save';

  @override
  String get partsNewPlaylist => 'New playlist';

  @override
  String partsAddedToPlaylist(String name) {
    return 'Added to “$name”';
  }

  @override
  String get partsSongsGone => 'The song or playlist is gone';

  @override
  String get playerUnlike => 'Remove from Favorites';

  @override
  String get playerLike => 'Add to Favorites';

  @override
  String get playerNoTrack => 'No track';

  @override
  String get playerCollapse => 'Collapse';

  @override
  String get playerMore => 'More';

  @override
  String get playerMenuSong => 'Song';

  @override
  String get playerMenuGo => 'Go to';

  @override
  String get playerMenuHelp => 'Help';

  @override
  String get playerMenuSound => 'Sound';

  @override
  String get playerLosslessOnce => 'Play this song lossless';

  @override
  String get playerLosslessMissed => 'No lossless copy of this song was found';

  @override
  String get playerUndislike => 'Remove “Dislike”';

  @override
  String get playerToPodcast => 'Go to podcast';

  @override
  String get playerAddToPlaylist => 'Add to playlist';

  @override
  String get playerAddedToDownloads => 'Added to Downloads';

  @override
  String get playerDownload => 'Download';

  @override
  String get playerShuffle => 'Shuffle';

  @override
  String get playerPrevious => 'Previous';

  @override
  String get playerNext => 'Next';

  @override
  String get playerRepeatOff => 'Repeat off';

  @override
  String get playerRepeatAll => 'Repeat all';

  @override
  String get playerRepeatOne => 'Repeat one';

  @override
  String get playerQueue => 'Queue';

  @override
  String playerWaitSeconds(int seconds) {
    return ' · ${seconds}s';
  }

  @override
  String get miniSearchingSource => 'Looking for source';

  @override
  String get miniPreparingAudio => 'Preparing audio';

  @override
  String get miniNoSource => 'Source not found — retry';

  @override
  String get miniUnknownTrack => 'Track not found on server — search again';

  @override
  String get miniNoAccess => 'Access denied — check build key';

  @override
  String get miniNoAnswer => 'Server timed out — retry';

  @override
  String get miniDropped => 'Connection lost — retry';

  @override
  String get miniFailed => 'Playback failed — retry';

  @override
  String miniWaitSeconds(int seconds) {
    return ' · ${seconds}s';
  }

  @override
  String get libraryTitle => 'Library';

  @override
  String get libraryFavorites => 'Favorite songs';

  @override
  String libraryTracksCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tracks',
      one: '$count track',
    );
    return '$_temp0';
  }

  @override
  String get libraryMediaSection => 'Library';

  @override
  String get libraryRatingsSection => 'My ratings';

  @override
  String get libraryHistorySubtitle => 'Recent';

  @override
  String get libraryDownloadsSubtitle => 'Offline';

  @override
  String get libraryHistory => 'History';

  @override
  String get libraryPlaylists => 'Playlists';

  @override
  String libraryPlaylistsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count playlists',
      one: '$count playlist',
    );
    return '$_temp0';
  }

  @override
  String get libraryDownloads => 'Downloads';

  @override
  String get libraryDevice => 'Device music';

  @override
  String get libraryDeviceSubtitle => 'From storage';

  @override
  String get libraryDeviceTile => 'On this phone';

  @override
  String get libraryImport => 'Import';

  @override
  String get libraryImportSubtitle => 'Spotify, Apple Music, M3U, text';

  @override
  String get libraryFavoritesEmpty => 'No Favorites yet';

  @override
  String get libraryHistoryEmpty => 'History is empty';

  @override
  String get libraryNewPlaylist => 'New playlist';

  @override
  String get libraryPlaylistNotFound => 'Playlist no longer exists';

  @override
  String get libraryRename => 'Rename';

  @override
  String libraryDeletePlaylistConfirm(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get libraryDeletePlaylistMessage =>
      'Songs will remain in the catalog and favorites.';

  @override
  String get libraryCancel => 'Cancel';

  @override
  String get libraryDelete => 'Delete';

  @override
  String get libraryDeletePlaylist => 'Delete playlist';

  @override
  String get libraryPlaylistEmpty => 'Empty. Add songs from search or albums';

  @override
  String get libraryPlayPlaylist => 'Play playlist';

  @override
  String memoryGigabytes(String gb) {
    return '$gb GB';
  }

  @override
  String get memoryDeleteAllTitle => 'Delete all downloads?';

  @override
  String get memoryDeleteAllMessage =>
      'All downloaded songs will be deleted from your phone.';

  @override
  String get memoryCancel => 'Cancel';

  @override
  String get memoryDelete => 'Delete';

  @override
  String get memoryTitle => 'Storage';

  @override
  String memoryLegendDownloaded(String size) {
    return 'Downloaded · $size';
  }

  @override
  String memoryLegendReserve(String size) {
    return 'Played cache · $size';
  }

  @override
  String memoryLegendFree(String size) {
    return 'Free · $size';
  }

  @override
  String get memoryReserveTitle => 'Cache of played songs';

  @override
  String get memoryReserveOff => 'Off';

  @override
  String get memoryClearReserve => 'Clear cache';

  @override
  String get memoryDeleteAll => 'Delete all downloads';

  @override
  String get navHome => 'Home';

  @override
  String get navBrowse => 'Browse';

  @override
  String get navNews => 'News';

  @override
  String get navSearch => 'Search';

  @override
  String get navLibrary => 'Library';

  @override
  String get newsTitle => 'News';

  @override
  String get newsConsentDescription =>
      'News comes from this server and its sources. To build the feed, the server connects to the internet directly. Your phone does not connect outside.';

  @override
  String get newsConsentGotIt => 'Got it';

  @override
  String get newsUnavailable => 'News unavailable';

  @override
  String get newsServerDisabled => 'News: disabled on this server';

  @override
  String get newsReadFull => 'Read in full';

  @override
  String get newsSource => 'Source';

  @override
  String get newsPlay => 'Listen';

  @override
  String get newsEmpty => 'No news yet';

  @override
  String get newsSuggestionsTitle => 'You often listen to';

  @override
  String get newsFollowAll => 'Follow all';

  @override
  String get newsChannels => 'Channels';

  @override
  String get channelsTitle => 'Channels';

  @override
  String get channelsUnavailable => 'Channels unavailable';

  @override
  String get channelsAddErrorNotPublic =>
      'This is a private network address — the channel cannot be added';

  @override
  String get channelsAddErrorTooMany => 'Channel limit reached';

  @override
  String get channelsAddErrorNotFeed => 'No news feed found at this link';

  @override
  String get channelsAddErrorFailed => 'The server did not answer';

  @override
  String get channelsCuratedHeading => 'Curated channels';

  @override
  String get channelsOwnHeading => 'Your channels';

  @override
  String get channelsOwnEmpty => 'Nothing yet';

  @override
  String get channelsAddHeading => 'Add by link';

  @override
  String get channelsAddLinkHint => 'Link: @channel, t.me/… or a site';

  @override
  String get channelsAddButton => 'Add';

  @override
  String get channelsPopularHeading => 'Popular on this server';

  @override
  String get channelsPopularEmpty =>
      'Channels added by at least three people will show up here';

  @override
  String channelsPopularAdded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count people added it',
      one: '$count person added it',
    );
    return '$_temp0';
  }

  @override
  String get downloadsTitle => 'Downloads';

  @override
  String downloadsProgress(int done, int total) {
    return 'Downloaded $done of $total';
  }

  @override
  String downloadsFree(int size) {
    return '$size GB free';
  }

  @override
  String get downloadsHoldMetered =>
      'Paused: downloading over mobile data is off';

  @override
  String get downloadsHoldNoRoom =>
      'Paused: not enough free space on the phone';

  @override
  String get downloadsAllowMobile => 'Download over mobile data';

  @override
  String downloadsMemoryOf(String used, String total) {
    return 'Storage · $used of $total';
  }

  @override
  String downloadsMemory(String used) {
    return 'Storage · $used';
  }

  @override
  String get downloadsEpisodes => 'Podcast episodes';

  @override
  String get downloadsEmpty => 'No downloads yet';

  @override
  String downloadsSizeMb(String size) {
    return '$size MB';
  }

  @override
  String get downloadsRemove => 'Delete';

  @override
  String get downloadsDownloadAll => 'Download all';

  @override
  String downloadsDownloading(int done, int total) {
    return 'Downloading $done of $total';
  }

  @override
  String get downloadsOnPhone => 'On the phone';

  @override
  String downloadsOnPhoneDetail(String songs, int size) {
    return 'On the phone: $songs · $size MB';
  }

  @override
  String downloadsSongs(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs',
      one: '$count song',
    );
    return '$_temp0';
  }

  @override
  String get downloadsRemoveFromPhone => 'Remove from phone';

  @override
  String downloadsNotificationProgress(String numFinished, String numTotal) {
    return 'Downloading $numFinished of $numTotal';
  }

  @override
  String get downloadsNotificationComplete => 'Download complete';

  @override
  String get storageTitle => 'Space for music';

  @override
  String get storageDescription =>
      'Songs you play stay on the phone, so replays don\'t use data. 0 keeps nothing; change the size later in Downloads.';

  @override
  String get storageNoRoom =>
      'Almost no free space — keeping played songs is off.';

  @override
  String storageValue(int count) {
    return '$count GB';
  }

  @override
  String get storageNext => 'Next';

  @override
  String storageHintFits(int flac, int opus) {
    return '≈ $flac songs in FLAC / $opus in Opus';
  }

  @override
  String get storageHintNothing => 'Not enough room for a single song';

  @override
  String get importFileTooLarge =>
      'File is larger than 10 MiB. Choose a smaller file.';

  @override
  String get importChooseTrack => 'Choose a song';

  @override
  String get importNone => 'None';

  @override
  String get importCancel => 'Cancel';

  @override
  String get importDescription =>
      'Transfer your music: Spotify — CSV or ZIP from Exportify; Apple Music — library XML; M3U/M3U8 or \"artist — song\" lines. Yandex — via TuneMyMusic in CSV.';

  @override
  String get importPickFile => 'Choose file';

  @override
  String get importPasteText => 'Paste text';

  @override
  String get importTextHint => 'Artist — song, one per line';

  @override
  String get importSend => 'Send';

  @override
  String get importSaveAll => 'Save all';

  @override
  String importListFound(int found, int total) {
    return '$found of $total found';
  }

  @override
  String get importSaved => 'Saved';

  @override
  String get importNotFound => 'Not found';

  @override
  String get importSelected => 'Selected';

  @override
  String get importDoubtful => 'Doubtful';

  @override
  String get importFound => 'Found';

  @override
  String importSummary(int found, int total, int doubtful, int missing) {
    return '$found of $total found · $doubtful doubtful · $missing missing';
  }

  @override
  String get importToFavorites => 'Add to Favorites';

  @override
  String get importSave => 'Save';

  @override
  String get importDoubtfulHint =>
      'Checking doubtful songs is optional. Missing songs stay dimmed in the playlist; only found ones go to Favorites.';

  @override
  String get importTitle => 'Import';

  @override
  String get accountTitle => 'Account';

  @override
  String get accountAutoReports => 'Send reports automatically';

  @override
  String get accountNews => 'News';

  @override
  String get accountScrobble => 'ListenBrainz and Last.fm';

  @override
  String get accountLogout => 'Log out';

  @override
  String get accountSwitchServer => 'Switch server';

  @override
  String get accountLogoutConfirm => 'Log out?';

  @override
  String get accountSwitchServerConfirm => 'Switch server?';

  @override
  String get accountAutoReportsConfirm => 'Send reports automatically?';

  @override
  String get accountAutoReportsDescription =>
      'When the app crashes, it will send a short report to your server automatically: what broke, on which screen and where in the code. No song titles, search queries or phone address.';

  @override
  String get accountCancel => 'Cancel';

  @override
  String get accountSendReports => 'Send';

  @override
  String get accountLeaveWarning =>
      'You will need to enter your password again to come back.';

  @override
  String get appPlayNext => 'Playing next';

  @override
  String get appEnqueued => 'Added to queue';

  @override
  String get appPlaybackChannel => 'Playback';

  @override
  String get sleepTimerTitle => 'Sleep timer';

  @override
  String get sleepTimer15Min => '15 min';

  @override
  String get sleepTimer30Min => '30 min';

  @override
  String get sleepTimer45Min => '45 min';

  @override
  String get sleepTimer60Min => '1 hour';

  @override
  String get sleepTimerEndOfSong => 'End of song';

  @override
  String sleepTimerMinLeft(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n min left',
      one: '$n min left',
    );
    return '$_temp0';
  }

  @override
  String get sleepTimerTurnOff => 'Turn off';

  @override
  String get equalizerTitle => 'Equalizer';

  @override
  String get equalizerFlat => 'Flat';

  @override
  String get equalizerBass => 'Bass';

  @override
  String get equalizerTreble => 'Treble';

  @override
  String get equalizerVocal => 'Vocal';

  @override
  String get equalizerWaiting =>
      'The equalizer will set up with the first song';

  @override
  String get equalizerMissing => 'This phone has no equalizer';

  @override
  String equalizerHz(String value) {
    return '$value Hz';
  }

  @override
  String equalizerKhz(String value) {
    return '$value kHz';
  }

  @override
  String get lyricsNone => 'No lyrics for this song yet';

  @override
  String get aboutTitle => 'About the app';

  @override
  String get aboutCredits =>
      'Thank you to the projects this app is built on:\n\n• Lyrics — LRCLIB\n• Music catalog — MusicBrainz\n• Album covers — Cover Art Archive\n• Artist photos — Wikimedia Commons, with the author and licence under each photo';

  @override
  String get aboutLicenses => 'Licences';

  @override
  String get aboutClose => 'Close';

  @override
  String get lyricsCredit => 'Lyrics: LRCLIB';

  @override
  String get lyricsInstrumental => 'Instrumental';

  @override
  String get problemTitle => 'Report a problem';

  @override
  String get problemReasonWrongTrack => 'Wrong song plays';

  @override
  String get problemReasonNoPlay => 'Doesn\'t play';

  @override
  String get problemReasonBadSound => 'Bad sound';

  @override
  String get problemReasonCover => 'Wrong or missing cover';

  @override
  String get problemReasonWrongName => 'Wrong title or name';

  @override
  String get problemReasonOther => 'Other';

  @override
  String get problemTextHint => 'A few words, if you like';

  @override
  String get problemSend => 'Send';

  @override
  String get problemSent => 'Thanks, report sent';

  @override
  String get problemTooMany => 'Too many reports. Try again in an hour.';

  @override
  String get problemFailed => 'Could not send. Try again.';

  @override
  String get deviceTabSongs => 'Songs';

  @override
  String get deviceTabAlbums => 'Albums';

  @override
  String get deviceTabArtists => 'Artists';

  @override
  String get deviceTabFolders => 'Folders';

  @override
  String get deviceNoAccess =>
      'To show the music on this phone, the app needs permission.';

  @override
  String get deviceAllow => 'Allow';

  @override
  String get deviceDeniedForever =>
      'Access to music is denied. You can allow it in the phone settings.';

  @override
  String get deviceOpenSettings => 'Open settings';

  @override
  String get deviceEmpty => 'No music found on this phone';

  @override
  String get deviceFailed => 'Could not read the music on this phone';

  @override
  String get deviceRefresh => 'Refresh';

  @override
  String get deviceRefreshFailed => 'Could not refresh the list';

  @override
  String get deviceUntitled => 'Untitled';

  @override
  String get deviceBack => 'Back to the list';

  @override
  String get deviceTabEmpty => 'Nothing here yet';

  @override
  String deviceSongCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs',
      one: '$count song',
    );
    return '$_temp0';
  }

  @override
  String get podcastsTitle => 'Podcasts';

  @override
  String get browseBooks => 'Audiobooks';

  @override
  String get browseNotSetUp => 'Not set up on the server';

  @override
  String get audiobooksTitle => 'Audiobooks';

  @override
  String get podcastsSearchHint => 'Find a podcast';

  @override
  String get podcastsLanguages => 'Languages';

  @override
  String get podcastsContinue => 'Continue';

  @override
  String get podcastsNewEpisodes => 'New episodes';

  @override
  String get podcastsSubscriptions => 'Subscriptions';

  @override
  String get podcastsPopular => 'Popular';

  @override
  String get podcastsCategories => 'Categories';

  @override
  String get podcastsSubscribe => 'Subscribe';

  @override
  String get podcastsSubscribed => 'Subscribed';

  @override
  String get podcastsSubscribeFailed => 'Couldn\'t subscribe. Try again.';

  @override
  String get podcastsSearchFailed => 'Search failed. Check the connection.';

  @override
  String get podcastsNothingFound => 'Nothing found';

  @override
  String get podcastsSearchAllLanguages => 'Search in all languages';

  @override
  String get podcastsLoadFailed => 'Couldn\'t load podcasts';

  @override
  String get podcastsRetry => 'Try again';

  @override
  String get podcastsEmpty => 'Nothing here yet';

  @override
  String get podcastsAllLanguages => 'All languages';

  @override
  String get podcastAbout => 'About';

  @override
  String get podcastEpisodes => 'Episodes';

  @override
  String get podcastNewestFirst => 'Newest first';

  @override
  String get podcastOldestFirst => 'Oldest first';

  @override
  String get podcastNoEpisodes => 'No episodes yet';

  @override
  String get podcastUntitled => 'Untitled episode';

  @override
  String get podcastDownload => 'Download';

  @override
  String get podcastDownloading => 'Downloading';

  @override
  String get podcastOnPhone => 'On the phone';

  @override
  String get podcastDownloadFailed => 'Download failed';

  @override
  String get podcastNoRoom => 'Not enough space on the phone';

  @override
  String get podcastMetered => 'Downloads over mobile data are off';

  @override
  String get podcastPlay => 'Play';

  @override
  String get podcastEpisodesFailed => 'Couldn\'t load episodes';

  @override
  String podcastHoursMinutes(int hours, int minutes) {
    return '$hours h $minutes min';
  }

  @override
  String podcastMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String get playerSkipBack => 'Back 15 seconds';

  @override
  String get playerSkipForward => 'Forward 30 seconds';

  @override
  String get playerSpeed => 'Speed';

  @override
  String get knownAsHeading => 'Also known as';

  @override
  String knownAsSpoken(String name) {
    return 'Also known as $name';
  }

  @override
  String get crashTitle => 'The app closed with an error last time';

  @override
  String get crashBody =>
      'Send a report? It holds only places in the code: no songs, searches or addresses.';

  @override
  String get crashSend => 'Send report';

  @override
  String get crashSkip => 'Not now';

  @override
  String get crashNever => 'Don\'t ask again';

  @override
  String get crashSent => 'Report sent';

  @override
  String get crashNotSent => 'Report not sent';

  @override
  String get spokenSpeed => 'Speed';

  @override
  String get spokenDownload => 'Download';

  @override
  String get spokenDownloaded => 'Downloaded';

  @override
  String get spokenSleep => 'Sleep timer';

  @override
  String get spokenQueue => 'Queue';

  @override
  String get spokenParts => 'Parts';

  @override
  String get spokenRemaining => 'Left';

  @override
  String spokenRemainingMinutes(int m) {
    return '$m min';
  }

  @override
  String spokenRemainingHoursMinutes(int h, int m) {
    return '$h h $m min';
  }

  @override
  String get libraryBooks => 'Audiobooks';

  @override
  String get booksSearchHint => 'Title or author';

  @override
  String get booksShelfTitle => 'My shelf';

  @override
  String get booksEmptyShelf =>
      'Your shelf is empty.\nFind a book in the search above and tap “To shelf”.';

  @override
  String get booksLoadFailed => 'Failed to load shelf';

  @override
  String get booksRetry => 'Try again';

  @override
  String get booksSearching => 'Searching…';

  @override
  String get booksSearchFailed => 'Search failed';

  @override
  String get booksNothingFound => 'Nothing found';

  @override
  String get booksLanguages => 'Languages';

  @override
  String get booksAllLanguages => 'All languages';

  @override
  String get booksNoInLanguages => 'No books in your languages';

  @override
  String get booksSearchAllLanguages => 'Search all languages';

  @override
  String get booksAdd => 'To shelf';

  @override
  String get booksAdding => 'Adding…';

  @override
  String get booksOnShelf => 'On shelf';

  @override
  String get booksListen => 'Listen';

  @override
  String get booksFailureOffline => 'No connection';

  @override
  String get booksFailureUnavailable => 'Service unavailable';

  @override
  String get booksFailureSearchUnavailable => 'Search unavailable';

  @override
  String get booksFailureExpired => 'Link expired';

  @override
  String get booksFailureNoSpace => 'Not enough space';

  @override
  String get booksFailureLimit => 'Shelf limit reached';

  @override
  String get booksFailureNotABook => 'Not an audiobook';

  @override
  String get booksFailureNotOnShelf => 'Book not on shelf';

  @override
  String get booksFailureSignedOut => 'Sign-in required';

  @override
  String get booksFailureBroken => 'Invalid data';

  @override
  String get bookPageAddToShelf => 'Add to shelf';

  @override
  String get bookPageAddFailed => 'Couldn\'t add to shelf';

  @override
  String get bookPageListen => 'Listen';

  @override
  String get bookPageContinue => 'Continue';

  @override
  String get bookPageRestart => 'Start over';

  @override
  String get bookPageRemoveFromShelf => 'Remove from shelf';

  @override
  String get bookPageRemoveConfirm => 'Remove book from shelf?';

  @override
  String get bookPageRemoveYes => 'Remove';

  @override
  String get bookPageCancel => 'Cancel';

  @override
  String get bookPageNarrator => 'Narrator';

  @override
  String get bookPageLanguage => 'Language';

  @override
  String get bookPageDuration => 'Duration';

  @override
  String get bookPageParts => 'Parts';

  @override
  String get bookPageYear => 'Recording year';

  @override
  String get bookPagePartsAfterAdding => 'after adding';

  @override
  String bookPagePartsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count parts',
      one: '$count part',
    );
    return '$_temp0';
  }

  @override
  String get bookPageGone =>
      'The book was removed from the shelf on another device';

  @override
  String get bookPageToMyShelf => 'To my shelf';

  @override
  String get foreignTabLibrary => 'Library';

  @override
  String get foreignTabFavorites => 'Favorites';

  @override
  String get foreignLeave => 'Sign out';

  @override
  String get foreignRetry => 'Retry';

  @override
  String get foreignLoadFailed => 'Could not load — check your connection';

  @override
  String get foreignLikeFailed => 'Could not change the favorite';

  @override
  String get foreignAlbums => 'Albums';

  @override
  String get foreignArtists => 'Artists';

  @override
  String get foreignFavoritesEmpty => 'No favorite songs yet';

  @override
  String get foreignLike => 'Add to favorites';

  @override
  String get foreignUnlike => 'Remove from favorites';

  @override
  String get foreignBack => 'Back';

  @override
  String languageName(String code) {
    String _temp0 = intl.Intl.selectLogic(code, {
      'ru': 'Russian',
      'en': 'English',
      'uk': 'Ukrainian',
      'de': 'German',
      'fr': 'French',
      'es': 'Spanish',
      'it': 'Italian',
      'pl': 'Polish',
      'pt': 'Portuguese',
      'tr': 'Turkish',
      'be': 'Belarusian',
      'zh': 'Chinese',
      'ja': 'Japanese',
      'ko': 'Korean',
      'other': '',
    });
    return '$_temp0';
  }

  @override
  String get loginErrorBadCode =>
      'The code did not work: check the name and the code, or ask the admin for a new one';

  @override
  String get loginErrorWeakPassword =>
      'The password needs 8 or more characters';

  @override
  String get loginHaveCode => 'First sign-in with a code';

  @override
  String get loginHavePassword => 'I already have a password';

  @override
  String get loginCode => 'Code from the admin';

  @override
  String get loginNewPassword => 'Make up a password (8 or more characters)';

  @override
  String get loginRepeatPassword => 'Repeat the password';

  @override
  String get loginPasswordsDiffer => 'The passwords do not match';

  @override
  String get loginClaim => 'Save the password and sign in';

  @override
  String get accountChangePassword => 'Change password';

  @override
  String get passwordOld => 'Current password';

  @override
  String get passwordChanged =>
      'Password changed. Other devices are signed out';

  @override
  String get passwordWrongOld => 'The current password is wrong';

  @override
  String get passwordFailed => 'The server did not answer. Try again';

  @override
  String get passwordSave => 'Save';
}
