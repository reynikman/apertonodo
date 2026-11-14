// FT-718: "Audiobooks" page — shelf and book search.
import 'dart:async';

import 'package:flutter/material.dart';

import '../book_client.dart';
import '../book_search.dart';
import '../book_shelf.dart';
import '../listening_languages.dart';
import '../theme.dart';
import 'languages_sheet.dart';

class BooksPageTexts {
  final String searchHint;
  final String shelfTitle;
  final String emptyShelf;
  final String loadFailed;
  final String retry;
  final String searching;
  final String searchFailed;
  final String nothingFound;
  final String add;
  final String adding;
  final String onShelf;
  final String listen;
  final String Function(BookFailure) failure;
  final String languages;
  final String allLanguages;
  final String noBooksInLanguages;
  final String searchAllLanguages;
  final String Function(String code)? languageName;

  /// Release size in a search row (FT-864): duplicates of one book differ by it.
  final String Function(int bytes)? size;

  const BooksPageTexts({
    required this.searchHint,
    required this.shelfTitle,
    required this.emptyShelf,
    required this.loadFailed,
    required this.retry,
    required this.searching,
    required this.searchFailed,
    required this.nothingFound,
    required this.add,
    required this.adding,
    required this.onShelf,
    required this.listen,
    required this.failure,
    required this.languages,
    required this.allLanguages,
    required this.noBooksInLanguages,
    required this.searchAllLanguages,
    this.languageName,
    this.size,
  });
}

class BooksPage extends StatefulWidget {
  final BookShelfModel shelf;
  final BookSearchModel search;
  final ListeningLanguages? languages;
  final BooksPageTexts texts;
  final void Function(ShelfBook) onOpenBook;
  final void Function(ShelfBook) onListen;
  final Widget? continueSection;

  const BooksPage({
    super.key,
    required this.shelf,
    required this.search,
    this.languages,
    required this.texts,
    required this.onOpenBook,
    required this.onListen,
    this.continueSection,
  });

  @override
  State<BooksPage> createState() => _BooksPageState();
}

class _BooksPageState extends State<BooksPage> {
  final TextEditingController _searchController = TextEditingController();
  final Map<String, String> _refToBookId = {};
  String _lastQuery = '';
  BookFailure? _addError;

  @override
  void initState() {
    super.initState();
    _lastQuery = widget.search.query;
    widget.shelf.addListener(_onShelfChanged);
    widget.search.addListener(_onSearchChanged);
    if (!widget.shelf.loaded) {
      widget.shelf.load();
    }
  }

  @override
  void didUpdateWidget(BooksPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shelf != oldWidget.shelf) {
      oldWidget.shelf.removeListener(_onShelfChanged);
      widget.shelf.addListener(_onShelfChanged);
      if (!widget.shelf.loaded) {
        widget.shelf.load();
      }
    }
    if (widget.search != oldWidget.search) {
      oldWidget.search.removeListener(_onSearchChanged);
      widget.search.addListener(_onSearchChanged);
      _lastQuery = widget.search.query;
    }
  }

  @override
  void dispose() {
    widget.shelf.removeListener(_onShelfChanged);
    widget.search.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onShelfChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _onSearchChanged() {
    if (widget.search.query != _lastQuery) {
      _lastQuery = widget.search.query;
      _addError = null;
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _handleAdd(FoundBook book) async {
    final ref = book.ref;
    final bookId = _refToBookId[ref];
    if (widget.shelf.isBusy(ref) ||
        (bookId != null && widget.shelf.has(bookId))) {
      return;
    }
    setState(() {
      _addError = null;
    });
    final previousIds = widget.shelf.books.map((b) => b.id).toSet();
    final failure = await widget.shelf.add(ref);
    if (!mounted) return;
    setState(() {
      if (failure != null) {
        _addError = failure;
      } else {
        ShelfBook? addedBook;
        for (final b in widget.shelf.books) {
          if (!previousIds.contains(b.id)) {
            addedBook = b;
            break;
          }
        }
        if (addedBook != null) {
          _refToBookId[ref] = addedBook.id;
        } else {
          for (final b in widget.shelf.books) {
            if (b.title == book.title && b.author == book.author) {
              _refToBookId[ref] = b.id;
              break;
            }
          }
        }
      }
    });
  }

  String _formatSubtitle({
    required String author,
    required String narrator,
    required int? year,
    int? sizeBytes,
  }) {
    final parts = <String>[];
    if (author.isNotEmpty) parts.add(author);
    if (narrator.isNotEmpty) parts.add(narrator);
    if (year != null) parts.add('$year');
    final size = widget.texts.size;
    if (size != null && sizeBytes != null && sizeBytes > 0) {
      parts.add(size(sizeBytes));
    }
    return parts.join(' · ');
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: TextField(
        key: const ValueKey('books-search'),
        controller: _searchController,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.search,
        style: const TextStyle(color: ApertonoColors.textPrimary),
        decoration: InputDecoration(
          hintText: widget.texts.searchHint,
          hintStyle: const TextStyle(color: ApertonoColors.textSecondary),
          prefixIcon: const Icon(
            Icons.search,
            color: ApertonoColors.textSecondary,
          ),
          filled: true,
          fillColor: ApertonoColors.surface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ApertonoRadii.large),
            borderSide: const BorderSide(color: ApertonoColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ApertonoRadii.large),
            borderSide: const BorderSide(color: ApertonoColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ApertonoRadii.large),
            borderSide: const BorderSide(color: ApertonoColors.borderStrong),
          ),
        ),
        onChanged: (val) {
          if (_addError != null) {
            setState(() {
              _addError = null;
            });
          }
          widget.search.setQuery(val);
        },
        onSubmitted: (_) {
          if (_addError != null) {
            setState(() {
              _addError = null;
            });
          }
          widget.search.submit();
        },
      ),
    );
  }

  Widget _buildAddError() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Semantics(
        key: const ValueKey('books-add-error'),
        liveRegion: true,
        child: Text(
          widget.texts.failure(_addError!),
          style: ApertonoText.trackArtist.copyWith(
            color: ApertonoColors.textSecondary,
            fontSize: 14,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildShelfBookRow(ShelfBook book) {
    final subtitle = _formatSubtitle(
      author: book.author,
      narrator: book.narrator,
      year: book.year,
    );
    final listenLabel = '${widget.texts.listen}: ${book.title}';

    return LayoutBuilder(
      builder: (context, constraints) {
        final isLargeFont = MediaQuery.textScalerOf(context).scale(1) > 1.3;
        final info = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(book.title, style: ApertonoText.trackTitle),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(subtitle, style: ApertonoText.trackArtist),
            ],
          ],
        );

        final listenButton = TextButton(
          key: ValueKey('listen-${book.id}'),
          onPressed: () => widget.onListen(book),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          child: Text(widget.texts.listen, semanticsLabel: listenLabel),
        );

        return InkWell(
          key: ValueKey('book-${book.id}'),
          onTap: () => widget.onOpenBook(book),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: isLargeFont
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [info, const SizedBox(height: 4), listenButton],
                    )
                  : Row(
                      children: [
                        Expanded(child: info),
                        const SizedBox(width: 8),
                        listenButton,
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSearchResultRow(FoundBook book) {
    final subtitle = _formatSubtitle(
      author: book.author,
      narrator: book.narrator,
      year: book.year,
      sizeBytes: book.sizeBytes,
    );
    final isBusy = widget.shelf.isBusy(book.ref);
    final bookId = _refToBookId[book.ref];
    final isOnShelf = bookId != null && widget.shelf.has(bookId);

    final String actionText;
    if (isBusy) {
      actionText = widget.texts.adding;
    } else if (isOnShelf) {
      actionText = widget.texts.onShelf;
    } else {
      actionText = widget.texts.add;
    }
    final semanticsLabel = book.title.isNotEmpty
        ? '$actionText: ${book.title}'
        : actionText;

    return LayoutBuilder(
      key: ValueKey('found-${book.ref}'),
      builder: (context, constraints) {
        final isLargeFont = MediaQuery.textScalerOf(context).scale(1) > 1.3;
        final info = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(book.title, style: ApertonoText.trackTitle),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(subtitle, style: ApertonoText.trackArtist),
            ],
          ],
        );

        final addButton = TextButton(
          key: ValueKey('add-${book.ref}'),
          onPressed: isBusy || isOnShelf ? null : () => _handleAdd(book),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          child: Text(actionText, semanticsLabel: semanticsLabel),
        );

        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: isLargeFont
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [info, const SizedBox(height: 4), addButton],
                  )
                : Row(
                    children: [
                      Expanded(child: info),
                      const SizedBox(width: 8),
                      addButton,
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _buildMainContent() {
    return ListView(
      children: [
        if (widget.continueSection != null) widget.continueSection!,
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Semantics(
            header: true,
            child: Text(
              widget.texts.shelfTitle,
              style: ApertonoText.sectionTitle.copyWith(
                color: ApertonoColors.textPrimary,
              ),
            ),
          ),
        ),
        if ((widget.shelf.loading || !widget.shelf.loaded) &&
            widget.shelf.books.isEmpty &&
            widget.shelf.failure == null)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: CircularProgressIndicator(
                semanticsLabel: widget.texts.searching,
              ),
            ),
          )
        else if (widget.shelf.failure != null && widget.shelf.books.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                key: const ValueKey('books-load-error'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      widget.texts.loadFailed,
                      style: ApertonoText.trackArtist.copyWith(
                        color: ApertonoColors.textSecondary,
                        fontSize: 16,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    key: const ValueKey('books-retry'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: () => widget.shelf.load(),
                    child: Text(widget.texts.retry),
                  ),
                ],
              ),
            ),
          )
        else if (widget.shelf.loaded && widget.shelf.books.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                widget.texts.emptyShelf,
                key: const ValueKey('books-empty'),
                style: ApertonoText.trackArtist.copyWith(fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
          )
        else
          for (final book in widget.shelf.books) _buildShelfBookRow(book),
      ],
    );
  }

  ListeningLanguages? get _languages =>
      widget.languages ?? widget.search.languages;

  void _openLanguages() {
    final languages = _languages;
    if (languages == null) return;
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        builder: (_) => LanguagesSheet(
          languages: languages,
          scope: LanguageScope.books,
          texts: LanguagesTexts(
            title: widget.texts.languages,
            all: widget.texts.allLanguages,
            name: widget.texts.languageName,
          ),
        ),
      ),
    );
  }

  Widget _buildLanguagesRow() {
    return InkWell(
      key: const ValueKey('books-languages'),
      onTap: _openLanguages,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.texts.languages,
                  style: ApertonoText.trackArtist.copyWith(
                    color: ApertonoColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
              const Icon(
                Icons.chevron_right,
                color: ApertonoColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    if (widget.search.searching) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: CircularProgressIndicator(
            semanticsLabel: widget.texts.searching,
          ),
        ),
      );
    }

    if (widget.search.failure != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Semantics(
            key: const ValueKey('books-search-error'),
            liveRegion: true,
            child: Text(
              widget.texts.searchFailed,
              style: ApertonoText.trackArtist.copyWith(
                color: ApertonoColors.textSecondary,
                fontSize: 16,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final hasLanguages = _languages != null;
    final hiddenByLanguage = widget.search.hiddenByLanguage;

    if (widget.search.searched && widget.search.results.isEmpty) {
      return Column(
        children: [
          if (hasLanguages) _buildLanguagesRow(),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: hiddenByLanguage > 0
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              widget.texts.noBooksInLanguages,
                              style: ApertonoText.trackArtist.copyWith(
                                fontSize: 16,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            key: const ValueKey('books-all-languages'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: () => widget.search.showAllLanguages(),
                            child: Text(widget.texts.searchAllLanguages),
                          ),
                        ],
                      )
                    : Semantics(
                        key: const ValueKey('books-nothing'),
                        liveRegion: true,
                        child: Text(
                          widget.texts.nothingFound,
                          style: ApertonoText.trackArtist.copyWith(
                            fontSize: 16,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
              ),
            ),
          ),
        ],
      );
    }

    return ListView(
      children: [
        if (hasLanguages) _buildLanguagesRow(),
        for (final book in widget.search.results) _buildSearchResultRow(book),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isSearching = widget.search.query.runes.length >= bookSearchMinChars;

    return Scaffold(
      backgroundColor: ApertonoColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildSearchBar(),
            if (_addError != null) _buildAddError(),
            Expanded(
              child: isSearching ? _buildSearchResults() : _buildMainContent(),
            ),
          ],
        ),
      ),
    );
  }
}
