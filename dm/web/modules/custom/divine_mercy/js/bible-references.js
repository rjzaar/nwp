/**
 * @file
 * Bible reference functionality for Divine Mercy module.
 * Allows users to click Bible references and open them in their preferred online Bible.
 */

(function (Drupal, drupalSettings, once) {
  'use strict';

  // Bible book data for different Bible sites
  const bibleData = {
    // Book names to number mapping (1-72)
    books: {
      'genesis': 1, 'gen': 1, 'gn': 1,
      'exodus': 2, 'ex': 2, 'exod': 2,
      'leviticus': 3, 'lev': 3, 'lv': 3,
      'numbers': 4, 'num': 4, 'nm': 4,
      'deuteronomy': 5, 'deut': 5, 'dt': 5,
      'joshua': 6, 'josh': 6, 'jos': 6,
      'judges': 7, 'judg': 7, 'jgs': 7,
      'ruth': 8, 'ru': 8, 'rut': 8,
      '1samuel': 9, '1sam': 9, '1sm': 9,
      '2samuel': 10, '2sam': 10, '2sm': 10,
      '1kings': 11, '1kgs': 11, '1ki': 11,
      '2kings': 12, '2kgs': 12, '2ki': 12,
      '1chronicles': 13, '1chr': 13, '1chron': 13,
      '2chronicles': 14, '2chr': 14, '2chron': 14,
      'ezra': 15, 'ezr': 15,
      'tobit': 16, 'tob': 16, 'tb': 16,
      'judith': 17, 'jdt': 17, 'jdth': 17,
      'esther': 18, 'est': 18, 'esth': 18,
      'job': 19, 'jb': 19,
      'psalms': 20, 'ps': 20, 'psalm': 20, 'pss': 20,
      'proverbs': 21, 'prov': 21, 'prv': 21,
      'ecclesiastes': 22, 'eccl': 22, 'eccles': 22, 'qoh': 22,
      'songofsongs': 23, 'song': 23, 'sg': 23, 'sos': 23, 'cant': 23,
      'wisdom': 24, 'wis': 24, 'ws': 24,
      'sirach': 25, 'sir': 25, 'ecclesiasticus': 25,
      'isaiah': 26, 'isa': 26, 'is': 26,
      'jeremiah': 27, 'jer': 27, 'jr': 27,
      'lamentations': 28, 'lam': 28, 'la': 28,
      'baruch': 29, 'bar': 29,
      'ezekiel': 30, 'ezek': 30, 'ez': 30,
      'daniel': 31, 'dan': 31, 'dn': 31,
      'hosea': 32, 'hos': 32,
      'joel': 33, 'jl': 33,
      'amos': 34, 'am': 34,
      'obadiah': 35, 'obad': 35, 'ob': 35,
      'jonah': 36, 'jon': 36,
      'micah': 37, 'mic': 37, 'mi': 37,
      'nahum': 38, 'nah': 38, 'na': 38,
      'habakkuk': 39, 'hab': 39, 'hb': 39,
      'zephaniah': 40, 'zeph': 40, 'zep': 40,
      'haggai': 41, 'hag': 41, 'hg': 41,
      'zechariah': 42, 'zech': 42, 'zec': 42,
      'malachi': 43, 'mal': 43,
      '1maccabees': 44, '1macc': 44, '1mac': 44, '1mc': 44,
      '2maccabees': 45, '2macc': 45, '2mac': 45, '2mc': 45,
      'matthew': 46, 'matt': 46, 'mt': 46,
      'mark': 47, 'mk': 47, 'mr': 47,
      'luke': 48, 'lk': 48, 'luk': 48,
      'john': 49, 'jn': 49, 'jhn': 49,
      'acts': 50, 'act': 50,
      'romans': 51, 'rom': 51, 'rm': 51,
      '1corinthians': 52, '1cor': 52, '1co': 52,
      '2corinthians': 53, '2cor': 53, '2co': 53,
      'galatians': 54, 'gal': 54,
      'ephesians': 55, 'eph': 55,
      'philippians': 56, 'phil': 56, 'php': 56,
      'colossians': 57, 'col': 57,
      '1thessalonians': 58, '1thess': 58, '1thes': 58, '1th': 58,
      '2thessalonians': 59, '2thess': 59, '2thes': 59, '2th': 59,
      '1timothy': 60, '1tim': 60, '1tm': 60,
      '2timothy': 61, '2tim': 61, '2tm': 61,
      'titus': 62, 'tit': 62, 'ti': 62,
      'philemon': 63, 'phlm': 63, 'phm': 63,
      'hebrews': 64, 'heb': 64,
      'james': 65, 'jas': 65, 'jm': 65,
      '1peter': 66, '1pet': 66, '1pt': 66,
      '2peter': 67, '2pet': 67, '2pt': 67,
      '1john': 68, '1jn': 68, '1jhn': 68,
      '2john': 69, '2jn': 69, '2jhn': 69,
      '3john': 70, '3jn': 70, '3jhn': 70,
      'jude': 71, 'jud': 71,
      'revelation': 72, 'rev': 72, 'rv': 72, 'apoc': 72, 'apocalypse': 72
    },

    // Full book names for BibleGateway
    fullNames: {
      1: 'Genesis', 2: 'Exodus', 3: 'Leviticus', 4: 'Numbers', 5: 'Deuteronomy',
      6: 'Joshua', 7: 'Judges', 8: 'Ruth', 9: '1+Samuel', 10: '2+Samuel',
      11: '1+Kings', 12: '2+Kings', 13: '1+Chronicles', 14: '2+Chronicles',
      15: 'Ezra', 16: 'Tobit', 17: 'Judith', 18: 'Esther', 19: 'Job',
      20: 'Psalms', 21: 'Proverbs', 22: 'Ecclesiastes', 23: 'Song+of+Songs',
      24: 'Wisdom', 25: 'Sirach', 26: 'Isaiah', 27: 'Jeremiah', 28: 'Lamentations',
      29: 'Baruch', 30: 'Ezekiel', 31: 'Daniel', 32: 'Hosea', 33: 'Joel',
      34: 'Amos', 35: 'Obadiah', 36: 'Jonah', 37: 'Micah', 38: 'Nahum',
      39: 'Habakkuk', 40: 'Zephaniah', 41: 'Haggai', 42: 'Zechariah', 43: 'Malachi',
      44: '1+Maccabees', 45: '2+Maccabees', 46: 'Matthew', 47: 'Mark', 48: 'Luke',
      49: 'John', 50: 'Acts', 51: 'Romans', 52: '1+Corinthians', 53: '2+Corinthians',
      54: 'Galatians', 55: 'Ephesians', 56: 'Philippians', 57: 'Colossians',
      58: '1+Thessalonians', 59: '2+Thessalonians', 60: '1+Timothy', 61: '2+Timothy',
      62: 'Titus', 63: 'Philemon', 64: 'Hebrews', 65: 'James', 66: '1+Peter',
      67: '2+Peter', 68: '1+John', 69: '2+John', 70: '3+John', 71: 'Jude', 72: 'Revelation'
    },

    // USCCB book names
    usccbNames: {
      1: 'genesis', 2: 'exodus', 3: 'leviticus', 4: 'numbers', 5: 'deuteronomy',
      6: 'joshua', 7: 'judges', 8: 'ruth', 9: '1samuel', 10: '2samuel',
      11: '1kings', 12: '2kings', 13: '1chronicles', 14: '2chronicles',
      15: 'ezra', 16: 'tobit', 17: 'judith', 18: 'esther', 19: 'job',
      20: 'psalms', 21: 'proverbs', 22: 'ecclesiastes', 23: 'songofsolomon',
      24: 'wisdom', 25: 'sirach', 26: 'isaiah', 27: 'jeremiah', 28: 'lamentations',
      29: 'baruch', 30: 'ezekiel', 31: 'daniel', 32: 'hosea', 33: 'joel',
      34: 'amos', 35: 'obadiah', 36: 'jonah', 37: 'micah', 38: 'nahum',
      39: 'habakkuk', 40: 'zephaniah', 41: 'haggai', 42: 'zechariah', 43: 'malachi',
      44: '1maccabees', 45: '2maccabees', 46: 'matthew', 47: 'mark', 48: 'luke',
      49: 'john', 50: 'acts', 51: 'romans', 52: '1corinthians', 53: '2corinthians',
      54: 'galatians', 55: 'ephesians', 56: 'philippians', 57: 'colossians',
      58: '1thessalonians', 59: '2thessalonians', 60: '1timothy', 61: '2timothy',
      62: 'titus', 63: 'philemon', 64: 'hebrews', 65: 'james', 66: '1peter',
      67: '2peter', 68: '1john', 69: '2john', 70: '3john', 71: 'jude', 72: 'revelation'
    },

    // CatholicBible.Online abbreviations
    cbAbbr: {
      1: 'OT/Gen/ch_', 2: 'OT/Ex/ch_', 3: 'OT/Lev/ch_', 4: 'OT/Num/ch_', 5: 'OT/Dt/ch_',
      6: 'OT/Jos/ch_', 7: 'OT/Judg/ch_', 8: 'OT/Ru/ch_', 9: 'OT/_Kgs/ch_', 10: 'OT/2_kgs/ch_',
      11: 'OT/3_Kgs/ch_', 12: 'OT/4_Kgs/ch_', 13: 'OT/1_Par/ch_', 14: 'OT/2_Par/ch_',
      15: 'OT/Esd/ch_', 16: 'OT/Tob/ch_', 17: 'OT/Jdt/ch_', 18: 'OT/Est/ch_', 19: 'OT/Job/ch_',
      20: 'OT/Ps/ch_', 21: 'OT/Prov/ch_', 22: 'OT/Eccl/ch_', 23: 'OT/Cant/ch_', 24: 'OT/Wis/ch_',
      25: 'OT/Eccle/ch_', 26: 'OT/Isa/ch_', 27: 'OT/Jer/ch_', 28: 'OT/Lam/ch_', 29: 'OT/Bar/ch_',
      30: 'OT/Exe/ch_', 31: 'OT/Dan/ch_', 32: 'OT/Os/ch_', 33: 'OT/Jo/ch_', 34: 'OT/Am/ch_',
      35: 'OT/Abd/ch_', 36: 'OT/Jon/ch_', 37: 'OT/Mch/ch_', 38: 'OT/Nah/ch_', 39: 'OT/Hab/ch_',
      40: 'OT/Sop/ch_', 41: 'OT/Agg/ch_', 42: 'OT/Zac/ch_', 43: 'OT/Mal/ch_',
      44: 'OT/1_Mac/ch_', 45: 'OT/2_Mac/ch_', 46: 'NT/Mat/ch_', 47: 'NT/Mk/ch_', 48: 'NT/Lk/ch_',
      49: 'NT/Jn/ch_', 50: 'NT/Act/ch_', 51: 'NT/Rom/ch_', 52: 'NT/1_Cor/ch_', 53: 'NT/2_Cor/ch_',
      54: 'NT/Gal/ch_', 55: 'NT/Eph/ch_', 56: 'NT/Phl/ch_', 57: 'NT/Col/ch_', 58: 'NT/1_Th/ch_',
      59: 'NT/2_Th/ch_', 60: 'NT/1_Tim/ch_', 61: 'NT/2_Tim/ch_', 62: 'NT/Tit/ch_', 63: 'NT/Phm/ch_',
      64: 'NT/Heb/ch_', 65: 'NT/Jas/ch_', 66: 'NT/1_Pet/ch_', 67: 'NT/2_Pet/ch_', 68: 'NT/1_Jn/ch_',
      69: 'NT/2_Jn/ch_', 70: 'NT/3_Jn/ch_', 71: 'NT/Jud/ch_', 72: 'NT/Apoc/ch_'
    }
  };

  // Available Bible versions
  const bibleVersions = [
    { id: 'NABRE', name: 'NABRE (USCCB)' },
    { id: 'DOUAY-RHEIMS', name: 'Douay-Rheims (drbo.org)' },
    { id: 'Douay-Rheims', name: 'Douay-Rheims (CatholicBible.Online)' },
    { id: 'Knox', name: 'Knox (CatholicBible.Online)' },
    { id: 'NRSVCE', name: 'NRSVCE (BibleGateway)' },
    { id: 'RSVCE', name: 'RSVCE (BibleGateway)' },
    { id: 'VULGATE', name: 'Vulgate (BibleGateway)' },
    { id: 'Vulgate', name: 'Vulgate (CatholicBible.Online)' },
    { id: 'DR-LB', name: 'Douay-Rheims / Vulgate Side-by-Side' },
    { id: 'New-Jerusalem', name: 'New Jerusalem Bible' },
    { id: 'DHH-Spanish', name: 'DHH Spanish Bible' }
  ];

  /**
   * Parse a Bible reference string into components.
   * Supports formats like: "Mt 25:31", "Matthew 25:31-34", "1 Cor 13:4-7", "1Cor 13:4"
   */
  function parseReference(refText) {
    // Normalize the reference
    let ref = refText.trim();

    // Match pattern: optional number (with or without space), book name, chapter:verse(-endverse)
    const pattern = /^(\d?\s*[A-Za-z]+)\s*(\d+):(\d+)(?:-(\d+))?$/;
    const match = ref.match(pattern);

    if (!match) {
      return null;
    }

    let bookName = match[1].toLowerCase().replace(/\s+/g, '');
    const chapter = parseInt(match[2], 10);
    const verse = parseInt(match[3], 10);
    const verseEnd = match[4] ? parseInt(match[4], 10) : null;

    // Find book number
    const bookNum = bibleData.books[bookName];
    if (!bookNum) {
      return null;
    }

    return {
      bookNum: bookNum,
      bookName: bookName,
      chapter: chapter,
      verse: verse,
      verseEnd: verseEnd
    };
  }

  /**
   * Open a Bible reference in the selected Bible.
   */
  function openReference(ref, selectedBible) {
    if (!ref) return;

    let url = '';
    const bookNum = ref.bookNum;
    let chapter = ref.chapter;
    const verse = ref.verse;
    const verseEnd = ref.verseEnd;

    // Handle Psalm numbering differences
    if (bookNum === 20 && chapter > 9 && chapter < 147) {
      if (selectedBible !== 'DHH-Spanish' && selectedBible !== 'NABRE') {
        chapter--;
      }
    }

    // Handle Malachi 4 -> 3 for NABRE
    if (selectedBible === 'NABRE' && bookNum === 43 && ref.chapter === 4) {
      const newVerse = verse + 18;
      url = `https://bible.usccb.org/bible/malachi/3?${newVerse}`;
      window.open(url, 'biblePopup', 'width=800,height=800');
      return;
    }

    switch (selectedBible) {
      case 'NABRE':
        url = `https://bible.usccb.org/bible/${bibleData.usccbNames[bookNum]}/${chapter}?${verse}`;
        break;

      case 'NRSVCE':
      case 'RSVCE':
      case 'VULGATE':
        let searchTerm = bibleData.fullNames[bookNum] + '+' + chapter + '%3A' + verse;
        if (verseEnd) {
          searchTerm += '-' + verseEnd;
        }
        url = `https://www.biblegateway.com/passage/?search=${searchTerm}&version=${selectedBible}`;
        break;

      case 'Knox':
      case 'Vulgate':
      case 'Douay-Rheims':
        const cbBase = selectedBible === 'Knox' ? 'knox' : (selectedBible === 'Vulgate' ? 'vulgate' : 'douay_rheims');
        const chapterPadded = chapter < 10 ? '0' + chapter : chapter;
        url = `https://catholicbible.online/${cbBase}/${bibleData.cbAbbr[bookNum]}${chapterPadded}`;
        break;

      case 'DOUAY-RHEIMS':
      case 'DR-LB':
        const drboBookNum = bookNum + 1;
        let chapterStr = chapter.toString();
        if (chapterStr.length < 3) chapterStr = '0' + chapterStr;
        if (chapterStr.length < 3) chapterStr = '0' + chapterStr;
        const basePath = selectedBible === 'DR-LB' ? 'drl/chapter' : 'chapter';
        url = `https://drbo.org/${basePath}/${drboBookNum}${chapterStr}.htm`;
        break;

      case 'New-Jerusalem':
        url = `https://www.catholic.org/bible/book.php?id=${bookNum}&bible_chapter=${chapter}`;
        break;

      case 'DHH-Spanish':
        // Spanish book names mapping would be needed for full support
        let spanishSearch = bibleData.fullNames[bookNum] + '+' + chapter + '%3A' + verse;
        if (verseEnd) {
          spanishSearch += '-' + verseEnd;
        }
        url = `https://www.biblegateway.com/passage/?search=${spanishSearch}&version=DHH`;
        break;
    }

    if (url) {
      window.open(url, 'biblePopup', 'width=800,height=800');
    }
  }

  /**
   * Find and linkify Bible references in text content.
   */
  function linkifyReferences(element) {
    // Pattern to match single Bible reference like "Mt 25:31", "1 Cor 13:4-7", "1Cor 13:4"
    const singleRefPattern = /(\d?\s*[A-Z][a-z]+)\s*(\d+):(\d+)(?:-(\d+))?/;

    // Pattern to match references in parentheses (may contain multiple comma-separated refs)
    const parenRefPattern = /\(([^)]+)\)/g;

    // Pattern to match standalone references (not in parentheses)
    const standaloneRefPattern = /(?<!\()\b(\d?\s*[A-Z][a-z]+)\s*(\d+):(\d+)(?:-(\d+))?(?!\s*[,)])/g;

    const walker = document.createTreeWalker(
      element,
      NodeFilter.SHOW_TEXT,
      null,
      false
    );

    const textNodes = [];
    let node;
    while (node = walker.nextNode()) {
      if (node.textContent.match(singleRefPattern)) {
        textNodes.push(node);
      }
    }

    textNodes.forEach(textNode => {
      const text = textNode.textContent;
      const parts = [];
      let lastIndex = 0;

      // First, handle parenthesized references (may contain multiple)
      let parenMatch;
      parenRefPattern.lastIndex = 0;

      // Collect all matches first
      const allMatches = [];

      while ((parenMatch = parenRefPattern.exec(text)) !== null) {
        const innerText = parenMatch[1];
        const refs = innerText.split(/,\s*/);
        const validRefs = [];

        refs.forEach(refStr => {
          const trimmed = refStr.trim();
          const ref = parseReference(trimmed);
          if (ref) {
            validRefs.push({ text: trimmed, ref: ref });
          }
        });

        if (validRefs.length > 0) {
          allMatches.push({
            start: parenMatch.index,
            end: parenMatch.index + parenMatch[0].length,
            fullMatch: parenMatch[0],
            refs: validRefs
          });
        }
      }

      // Also find standalone references not in parentheses
      standaloneRefPattern.lastIndex = 0;
      let standaloneMatch;
      while ((standaloneMatch = standaloneRefPattern.exec(text)) !== null) {
        // Check this isn't inside one of our paren matches
        const isInsideParen = allMatches.some(m =>
          standaloneMatch.index >= m.start && standaloneMatch.index < m.end
        );
        if (!isInsideParen) {
          const ref = parseReference(standaloneMatch[0]);
          if (ref) {
            allMatches.push({
              start: standaloneMatch.index,
              end: standaloneMatch.index + standaloneMatch[0].length,
              fullMatch: standaloneMatch[0],
              refs: [{ text: standaloneMatch[0], ref: ref }]
            });
          }
        }
      }

      // Sort matches by position
      allMatches.sort((a, b) => a.start - b.start);

      // Build the parts array
      allMatches.forEach(match => {
        // Add text before this match
        if (match.start > lastIndex) {
          parts.push(document.createTextNode(text.substring(lastIndex, match.start)));
        }

        // Handle the match
        if (match.refs.length === 1 && match.fullMatch.startsWith('(')) {
          // Single reference in parentheses
          const ref = match.refs[0].ref;
          parts.push(document.createTextNode('('));
          parts.push(createReferenceLink(match.refs[0].text, ref));
          parts.push(document.createTextNode(')'));
        } else if (match.refs.length > 1) {
          // Multiple references in parentheses
          parts.push(document.createTextNode('('));
          match.refs.forEach((refData, idx) => {
            if (idx > 0) {
              parts.push(document.createTextNode(', '));
            }
            parts.push(createReferenceLink(refData.text, refData.ref));
          });
          parts.push(document.createTextNode(')'));
        } else {
          // Standalone reference
          const ref = match.refs[0].ref;
          parts.push(createReferenceLink(match.fullMatch, ref));
        }

        lastIndex = match.end;
      });

      // Add remaining text
      if (lastIndex < text.length) {
        parts.push(document.createTextNode(text.substring(lastIndex)));
      }

      // Replace text node with parts
      if (parts.length > 1) {
        const span = document.createElement('span');
        parts.forEach(part => span.appendChild(part));
        textNode.parentNode.replaceChild(span, textNode);
      }
    });
  }

  /**
   * Create a clickable link for a Bible reference.
   */
  function createReferenceLink(displayText, ref) {
    const link = document.createElement('a');
    link.href = '#';
    link.className = 'bible-reference';
    link.textContent = displayText;
    link.dataset.book = ref.bookNum;
    link.dataset.chapter = ref.chapter;
    link.dataset.verse = ref.verse;
    if (ref.verseEnd) {
      link.dataset.verseEnd = ref.verseEnd;
    }
    link.addEventListener('click', function(e) {
      e.preventDefault();
      const selectedBible = localStorage.getItem('divineMercyBible') || 'NRSVCE';
      openReference({
        bookNum: parseInt(this.dataset.book, 10),
        chapter: parseInt(this.dataset.chapter, 10),
        verse: parseInt(this.dataset.verse, 10),
        verseEnd: this.dataset.verseEnd ? parseInt(this.dataset.verseEnd, 10) : null
      }, selectedBible);
    });
    return link;
  }

  /**
   * Create the Bible selector UI.
   */
  function createBibleSelector() {
    const savedBible = localStorage.getItem('divineMercyBible') || 'NRSVCE';

    const container = document.createElement('div');
    container.className = 'bible-selector-control';
    container.id = 'bible-selector-control';

    const label = document.createElement('label');
    label.htmlFor = 'bible-selector';
    label.className = 'bible-selector-label';
    label.textContent = Drupal.t('Bible Version');

    const select = document.createElement('select');
    select.id = 'bible-selector';
    select.className = 'bible-selector';

    bibleVersions.forEach(version => {
      const option = document.createElement('option');
      option.value = version.id;
      option.textContent = version.name;
      if (version.id === savedBible) {
        option.selected = true;
      }
      select.appendChild(option);
    });

    select.addEventListener('change', function() {
      localStorage.setItem('divineMercyBible', this.value);
    });

    container.appendChild(label);
    container.appendChild(select);

    return container;
  }

  // Expose linkifyReferences for use by other behaviors
  Drupal.divineMercy = Drupal.divineMercy || {};
  Drupal.divineMercy.linkifyBibleReferences = linkifyReferences;

  Drupal.behaviors.divineMercyBibleReferences = {
    attach: function (context, settings) {
      // Add Bible selector after font size control
      once('bible-selector', '#font-size-control', context).forEach(function(fontControl) {
        const selector = createBibleSelector();
        fontControl.parentNode.insertBefore(selector, fontControl.nextSibling);
      });

      // Linkify Bible references in content areas
      once('bible-linkify', '.divine-mercy-content, .jesus-words, .prayer-text', context).forEach(function(element) {
        linkifyReferences(element);
      });
    }
  };

})(Drupal, drupalSettings, once);
