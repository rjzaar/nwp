<?php

/**
 * @file
 * Import Divine Mercy prayers and novena days from source content.
 *
 * Run with: ddev drush php:script web/modules/custom/divine_mercy/scripts/import_content.php
 */

use Drupal\node\Entity\Node;
use Drupal\taxonomy\Entity\Term;

// Create taxonomy terms first.
$prayer_types = [
  'standard' => 'Standard Prayer',
  'chaplet_specific' => 'Chaplet Specific',
  'novena' => 'Novena Prayer',
  'opening' => 'Opening Prayer',
  'closing' => 'Closing Prayer',
];

$prayer_categories = [
  'leader' => 'Leader',
  'response' => 'Response',
  'full' => 'Full Prayer',
  'reflection' => 'Reflection',
];

echo "Creating taxonomy terms...\n";

// Create prayer_type terms.
foreach ($prayer_types as $machine_name => $label) {
  $existing = \Drupal::entityTypeManager()
    ->getStorage('taxonomy_term')
    ->loadByProperties(['vid' => 'prayer_type', 'name' => $label]);

  if (empty($existing)) {
    $term = Term::create([
      'vid' => 'prayer_type',
      'name' => $label,
    ]);
    $term->save();
    echo "  Created prayer_type: $label\n";
  }
  else {
    echo "  Skipped prayer_type (exists): $label\n";
  }
}

// Create prayer_category terms.
foreach ($prayer_categories as $machine_name => $label) {
  $existing = \Drupal::entityTypeManager()
    ->getStorage('taxonomy_term')
    ->loadByProperties(['vid' => 'prayer_category', 'name' => $label]);

  if (empty($existing)) {
    $term = Term::create([
      'vid' => 'prayer_category',
      'name' => $label,
    ]);
    $term->save();
    echo "  Created prayer_category: $label\n";
  }
  else {
    echo "  Skipped prayer_category (exists): $label\n";
  }
}

// Helper function to get term ID by name and vocabulary.
function get_term_id($vocab, $name) {
  $terms = \Drupal::entityTypeManager()
    ->getStorage('taxonomy_term')
    ->loadByProperties(['vid' => $vocab, 'name' => $name]);

  if (!empty($terms)) {
    return reset($terms)->id();
  }
  return NULL;
}

// Helper function to create or update a prayer node.
function create_prayer($title, $body, $type, $category, $order, $latin = '', $has_variant = FALSE, $variant_text = '') {
  // Check if prayer already exists.
  $existing = \Drupal::entityTypeManager()
    ->getStorage('node')
    ->loadByProperties(['type' => 'prayer', 'title' => $title]);

  if (!empty($existing)) {
    echo "  Skipped prayer (exists): $title\n";
    return reset($existing);
  }

  $type_tid = get_term_id('prayer_type', $type);
  $category_tid = get_term_id('prayer_category', $category);

  $node = Node::create([
    'type' => 'prayer',
    'title' => $title,
    'body' => [
      'value' => $body,
      'format' => 'basic_html',
    ],
    'field_prayer_type' => $type_tid ? ['target_id' => $type_tid] : [],
    'field_prayer_category' => $category_tid ? ['target_id' => $category_tid] : [],
    'field_prayer_order' => $order,
    'field_latin_text' => $latin ? [
      'value' => $latin,
      'format' => 'basic_html',
    ] : [],
    'field_has_variant' => $has_variant,
    'field_variant_text' => $variant_text ? [
      'value' => $variant_text,
      'format' => 'basic_html',
    ] : [],
    'status' => 1,
  ]);

  $node->save();
  echo "  Created prayer: $title\n";
  return $node;
}

echo "\nCreating prayer nodes...\n";

// Sign of the Cross.
create_prayer(
  'Sign of the Cross',
  'In the Name of the Father and of the Son and the Holy Spirit. Amen.',
  'Opening Prayer',
  'Full Prayer',
  1
);

// St. Faustina's Prayer for Sinners.
create_prayer(
  "St. Faustina's Prayer for Sinners",
  "O Jesus, eternal Truth, our Life, I call upon You and I beg Your mercy for poor sinners. O sweetest Heart of my Lord, full of pity and unfathomable mercy, I plead with You for poor sinners. O Most Sacred Heart, Fount of Mercy from which gush forth rays of inconceivable graces upon the entire human race, I beg of You light for poor sinners. O Jesus, be mindful of Your own bitter Passion and do not permit the loss of souls redeemed at so dear a price of Your most precious Blood. O Jesus, when I consider the great price of Your Blood, I rejoice at its immensity, for one drop alone would have been enough for the salvation of all sinners. Although sin is an abyss of wickedness and ingratitude, the price paid for us can never be equalled. Therefore, let every soul trust in the Passion of the Lord, and place its hope in His mercy. God will not deny His mercy to anyone. Heaven and earth may change, but God's mercy will never be exhausted. Oh, what immense joy burns in my heart when I contemplate Your incomprehensible goodness, O Jesus! I desire to bring all sinners to Your feet that they may glorify Your mercy throughout endless ages.\n\n(Diary of Saint Maria Faustina Kowalska, 72)",
  'Opening Prayer',
  'Full Prayer',
  2
);

// You expired, Jesus.
create_prayer(
  'You Expired, Jesus',
  "You expired, Jesus, but the source of life gushed forth for souls, and the ocean of mercy opened up for the whole world. O Fount of Life, unfathomable Divine Mercy, envelop the whole world and empty Yourself out upon us.",
  'Opening Prayer',
  'Full Prayer',
  3
);

// O Blood and Water.
create_prayer(
  'O Blood and Water',
  "O Blood and Water, which gushed forth from the Heart of Jesus as a fount of mercy for us, I trust in You!\n\n(Repeat 3 times)",
  'Opening Prayer',
  'Full Prayer',
  4
);

// Our Father.
create_prayer(
  'Our Father',
  "<strong>Leader:</strong> Our Father who art in heaven, hallowed be thy name, thy kingdom come, thy will be done on earth as it is in heaven.\n\n<strong>Response:</strong> Give us this day our daily bread; and forgive us our trespasses; as we forgive those who trespass against us; and lead us not into temptation but deliver us from evil. Amen.",
  'Standard Prayer',
  'Leader',
  10,
  "Pater noster, qui es in caelis, sanctificetur nomen tuum. Adveniat regnum tuum. Fiat voluntas tua, sicut in caelo et in terra. Panem nostrum quotidianum da nobis hodie, et dimitte nobis debita nostra sicut et nos dimittimus debitoribus nostris. Et ne nos inducas in tentationem, sed libera nos a malo. Amen."
);

// Hail Mary.
create_prayer(
  'Hail Mary',
  "<strong>Leader:</strong> Hail Mary full of grace, the Lord is with thee; blessed art thou among women; and blessed is the fruit of thy womb, Jesus.\n\n<strong>Response:</strong> Holy Mary, Mother of God, pray for us sinners, now and at the hour of our death. Amen.",
  'Standard Prayer',
  'Leader',
  11,
  "Ave Maria, gratia plena, Dominus tecum. Benedicta tu in mulieribus, et benedictus fructus ventris tui, Iesus. Sancta Maria, Mater Dei, ora pro nobis peccatoribus, nunc et in hora mortis nostrae. Amen.",
  TRUE,
  "<strong>Leader:</strong> Hail Mary full of grace, the Lord is with thee; blessed art thou among women; and blessed is the fruit of thy womb, Jesus.\n\n<strong>Flame of Love Response:</strong> Holy Mary, Mother of God, pray for us sinners. Spread the effect of grace of Thy Flame of Love over all humanity, now and at the hour of our death. Amen."
);

// Apostles' Creed.
create_prayer(
  "Apostles' Creed",
  "<strong>Leader:</strong> I believe in God the Father almighty, Creator of heaven and earth, and in Jesus Christ, his only Son, our Lord, who was conceived by the Holy Spirit, born of the Virgin Mary, suffered under Pontius Pilate, was crucified, died and was buried; He descended into hell; on the third day He rose again from the dead; He ascended into heaven, and is seated at the right hand of God the Father Almighty; from there He will come again to judge the living and the dead.\n\n<strong>Response:</strong> I believe in the Holy Spirit, the Holy Catholic Church, the communion of the saints, the forgiveness of sins, the resurrection of the body and life everlasting. Amen.",
  'Standard Prayer',
  'Leader',
  12,
  "Credo in Deum Patrem omnipotentem, Creatorem caeli et terrae, et in Iesum Christum, Filium Eius unicum, Dominum nostrum, qui conceptus est de Spiritu Sancto, natus ex Maria Virgine, passus sub Pontio Pilato, crucifixus, mortuus, et sepultus, descendit ad inferos, tertia die resurrexit a mortuis, ascendit ad caelos, sedet ad dexteram Dei Patris omnipotentis, inde venturus est iudicare vivos et mortuos. Credo in Spiritum Sanctum, sanctam Ecclesiam catholicam, sanctorum communionem, remissionem peccatorum, carnis resurrectionem, vitam aeternam. Amen."
);

// Eternal Father (Large Bead Prayer).
create_prayer(
  'Eternal Father',
  "Eternal Father, I offer You the Body and Blood, Soul and Divinity of Your dearly beloved Son, Our Lord Jesus Christ, in atonement for our sins and those of the whole world.",
  'Chaplet Specific',
  'Full Prayer',
  20,
  "Pater Aeterne, offero tibi Corpus et Sanguinem, Animam et Divinitatem dilectissimi Filii tui, Domini nostri Iesu Christi, in expiationem peccatorum nostrorum et totius mundi."
);

// For the Sake of His Sorrowful Passion (Small Bead Prayer).
create_prayer(
  'For the Sake of His Sorrowful Passion',
  "<strong>Leader:</strong> For the sake of His sorrowful Passion,\n\n<strong>Response:</strong> have mercy on us and on the whole world.",
  'Chaplet Specific',
  'Leader',
  21,
  "<strong>Leader:</strong> Pro dolorosa Eius Passione,\n\n<strong>Response:</strong> miserere nobis et totius mundi."
);

// Holy God (Closing Prayer - Trisagion).
create_prayer(
  'Holy God',
  "Holy God, Holy Mighty One, Holy Immortal One, have mercy on us and on the whole world.\n\n(Repeat 3 times)",
  'Closing Prayer',
  'Full Prayer',
  30,
  "Sanctus Deus, Sanctus Fortis, Sanctus Immortalis, miserere nobis et totius mundi."
);

// Optional Closing Prayer.
create_prayer(
  'Optional Closing Prayer',
  "O Greatly Merciful God, Infinite Goodness, today all mankind calls out from the abyss of its misery to Your mercy — to Your compassion, O God; and it is with its mighty voice of misery that it cries out. Gracious God, do not reject the prayer of this earth's exiles! O Lord, Goodness beyond our understanding, Who are acquainted with our misery through and through, and know that by our own power we cannot ascend to You, we implore You: anticipate us with Your grace and keep on increasing Your mercy in us, that we may faithfully do Your holy will all through our life and at death's hour. Let the omnipotence of Your mercy shield us from the darts of our salvation's enemies, that we may with confidence, as Your children, await Your [Son's] final coming — that day known to You alone. And we expect to obtain everything promised us by Jesus in spite of all our wretchedness. For Jesus is our Hope: through His merciful Heart, as through an open gate, we pass through to heaven.\n\n(Diary, 1570)",
  'Closing Prayer',
  'Full Prayer',
  31
);

// Eternal God Prayer.
create_prayer(
  'Eternal God Prayer',
  "Eternal God, in whom mercy is endless and the treasury of compassion inexhaustible; look kindly upon us and increase Your mercy in us, that in difficult moments we might not despair nor become despondent, but with great confidence submit ourselves to Your holy will, which is Love and Mercy itself.",
  'Closing Prayer',
  'Full Prayer',
  32
);

echo "\nCreating novena day nodes...\n";

// Novena Days data.
$novena_days = [
  1 => [
    'title' => 'Day 1 - All Mankind, Especially Sinners',
    'theme' => 'All Mankind, Especially Sinners',
    'weekday' => 5, // Friday
    'intention' => "Today, bring to Me all mankind, especially all sinners, and immerse them in the ocean of My mercy. In this way you will console Me in the bitter grief into which the loss of souls plunges Me.",
    'prayer' => "Most Merciful Jesus, whose very nature it is to have compassion on us and to forgive us, do not look upon our sins but upon our trust which we place in Your infinite goodness. Receive us all into the abode of Your Most Compassionate Heart, and never let us escape from it. We beg this of You by Your love which unites You to the Father and the Holy Spirit.\n\nOh, omnipotence of Divine Mercy, Salvation of sinful people, You are a sea of mercy and compassion; You aid those who entreat You with humility.\n\nEternal Father, turn Your merciful gaze upon all mankind and especially upon poor sinners, all enfolded in the Most Compassionate Heart of Jesus. For the sake of His sorrowful Passion, show us Your mercy, that we may praise the omnipotence of Your mercy forever and ever. Amen.",
  ],
  2 => [
    'title' => 'Day 2 - Priests and Religious',
    'theme' => 'Priests and Religious',
    'weekday' => 6, // Saturday
    'intention' => "Today bring to Me the souls of priests and religious, and immerse them in My unfathomable mercy. It was they who gave Me the strength to endure My bitter Passion. Through them, as through channels, My mercy flows out upon mankind.",
    'prayer' => "Most Merciful Jesus, from whom comes all that is good, increase Your grace in us, that we may perform worthy works of mercy, and that all who see them may glorify the Father of Mercy who is in heaven.\n\nThe fountain of God's love dwells in pure hearts, bathed in the Sea of Mercy, radiant as stars, bright as the dawn.\n\nEternal Father, turn Your merciful gaze upon the company [of chosen ones] in Your vineyard — upon the souls of priests and religious; and endow them with the strength of Your blessing. For the love of the Heart of Your Son in which they are enfolded, impart to them Your power and light, that they may be able to guide others in the way of salvation, and with one voice sing praise to Your boundless mercy for ages without end. Amen.",
  ],
  3 => [
    'title' => 'Day 3 - Devout and Faithful Souls',
    'theme' => 'Devout and Faithful Souls',
    'weekday' => 0, // Sunday
    'intention' => "Today bring to Me all devout and faithful souls, and immerse them in the ocean of My mercy. These souls brought Me consolation on the Way of the Cross. They were that drop of consolation in the midst of an ocean of bitterness.",
    'prayer' => "Most Merciful Jesus, from the treasury of Your mercy You impart Your graces in great abundance to each and all. Receive us into the abode of Your Most Compassionate Heart and never let us escape from It. We beg this of You by that most wondrous love for the heavenly Father with which Your Heart burns so fiercely.\n\nThe miracles of mercy are impenetrable. Neither the sinner nor just one will fathom them. When You cast upon us an eye of pity, You draw us all closer to Your love.\n\nEternal Father, turn Your merciful gaze upon faithful souls, as upon the inheritance of Your Son. For the sake of His sorrowful Passion, grant them Your blessing and surround them with Your constant protection. Thus may they never fail in love or lose the treasure of the holy faith, but rather, with all the hosts of Angels and Saints, may they glorify Your boundless mercy for endless ages. Amen.",
  ],
  4 => [
    'title' => 'Day 4 - Those Who Do Not Believe',
    'theme' => 'Those Who Do Not Believe',
    'weekday' => 1, // Monday
    'intention' => "Today bring to Me the pagans and those who do not yet know Me. I was thinking also of them during My bitter Passion, and their future zeal comforted My Heart. Immerse them in the ocean of My mercy.",
    'prayer' => "Most compassionate Jesus, You are the Light of the whole world. Receive into the abode of Your Most Compassionate Heart the souls of pagans who as yet do not know You. Let the rays of Your grace enlighten them that they, too, together with us, may extol Your wonderful mercy; and do not let them escape from the abode which is Your Most Compassionate Heart.\n\nMay the light of Your love enlighten the souls in darkness; Grant that these souls will know You, and, together with us, praise Your mercy.\n\nEternal Father, turn Your merciful gaze upon the souls of pagans and of those who as yet do not know You, but who are enclosed in the Most Compassionate Heart of Jesus. Draw them to the light of the Gospel. These souls do not know what great happiness it is to love You. Grant that they, too, may extol the generosity of Your mercy for endless ages. Amen.",
  ],
  5 => [
    'title' => 'Day 5 - Separated Brethren',
    'theme' => 'Separated Brethren',
    'weekday' => 2, // Tuesday
    'intention' => "Today bring to Me the souls of heretics and schismatics, and immerse them in the ocean of My mercy. During My bitter Passion they tore at My Body and Heart; that is, My Church. As they return to unity with the Church, My wounds heal, and in this way they alleviate My Passion.",
    'prayer' => "Most Merciful Jesus, Goodness Itself, You do not refuse light to those who seek it of You. Receive into the abode of Your Most Compassionate Heart the souls of heretics and schismatics. Draw them by Your light into the unity of the Church, and do not let them escape from the abode of Your Most Compassionate Heart; but bring it about that they, too, come to extol the generosity of Your mercy.\n\nEven for those who have torn the garment of Your unity, a fount of mercy flows from Your Heart. The omnipotence of Your mercy, Oh God, can lead these souls also out of error.\n\nEternal Father, turn Your merciful gaze upon the souls of heretics and schismatics, who have squandered Your blessings and misused Your graces by obstinately persisting in their errors. Do not look upon their errors, but upon the love of Your own Son and upon His bitter Passion, which He underwent for their sake, since they, too, are enclosed in the Most Compassionate Heart of Jesus. Bring it about that they also may glorify Your great mercy for endless ages. Amen.",
  ],
  6 => [
    'title' => 'Day 6 - Meek and Humble Souls',
    'theme' => 'Meek and Humble Souls',
    'weekday' => 3, // Wednesday
    'intention' => "Today bring to Me the meek and humble souls and the souls of little children, and immerse them in My mercy. These souls most closely resemble My Heart. They strengthened Me during My bitter agony. I saw them as earthly Angels, who would keep vigil at My altars. I pour out upon them whole torrents of grace. Only the humble soul is able to receive My grace. I favor humble souls with My confidence.",
    'prayer' => "Most Merciful Jesus, You yourself have said, \"Learn from Me for I am meek and humble of heart.\" Receive into the abode of Your Most Compassionate Heart all meek and humble souls and the souls of little children. These souls send all heaven into ecstasy and they are the heavenly Father's favorites. They are a sweet-smelling bouquet before the throne of God; God Himself takes delight in their fragrance. These souls have a permanent abode in Your Most Compassionate Heart, O Jesus, and they unceasingly sing out a hymn of love and mercy.\n\nEternal Father, turn Your merciful gaze upon meek and humble souls, and upon the souls of little children who are enfolded in the abode which is the Most Compassionate Heart of Jesus. These souls bear the closest resemblance to Your Son. Their fragrance rises from the earth and reaches Your very throne. Father of mercy and of all goodness, I beg You by the love You bear these souls and by the delight You take in them: Bless the whole world, that all souls together may sing out the praises of Your mercy for endless ages. Amen.",
  ],
  7 => [
    'title' => 'Day 7 - Those Who Venerate Divine Mercy',
    'theme' => 'Those Who Venerate Divine Mercy',
    'weekday' => 4, // Thursday
    'intention' => "Today bring to Me the souls who especially venerate and glorify My mercy, and immerse them in My mercy. These souls sorrowed most over My Passion and entered most deeply into My Spirit. They are living images of My Compassionate Heart. These souls will shine with a special brightness in the next life. Not one of them will go into the fire of hell. I shall particularly defend each one of them at the hour of death.",
    'prayer' => "Most Merciful Jesus, whose Heart is Love Itself, receive into the abode of Your Most Compassionate Heart the souls of those who particularly extol and venerate the greatness of Your mercy. These souls are mighty with the very power of God Himself. In the midst of all afflictions and adversities they go forward, confident of Your mercy. These souls are united to Jesus and carry all mankind on their shoulders. These souls will not be judged severely, but Your mercy will embrace them as they depart from this life.\n\nA soul who praises the goodness of his Lord is especially loved by Him. He is always close to the living fountain and draws graces from Mercy Divine.\n\nEternal Father, turn Your merciful gaze upon the souls who glorify and venerate Your greatest attribute, that of Your fathomless mercy, and who are enclosed in the Most Compassionate Heart of Jesus. These souls are a living Gospel; their hands are full of deeds of mercy, and their spirit, overflowing with joy, sings a canticle of mercy to You, O Most High! I beg You O God: Show them Your mercy according to the hope and trust they have placed in You. Let there be accomplished in them the promise of Jesus, who said to them, I Myself will defend as My own glory, during their lifetime, and especially at the hour of their death, those souls who will venerate My fathomless mercy. Amen.",
  ],
  8 => [
    'title' => 'Day 8 - Souls in Purgatory',
    'theme' => 'Souls in Purgatory',
    'weekday' => 5, // Friday (second Friday)
    'intention' => "Today bring to Me the souls who are in the prison of Purgatory, and immerse them in the abyss of My mercy. Let the torrents of My Blood cool down their scorching flames. All these souls are greatly loved by Me. They are making retribution to My justice. It is in your power to bring them relief. Draw all the indulgences from the treasury of My Church and offer them on their behalf. Oh, if you only knew the torments they suffer, you would continually offer for them the alms of the spirit and pay off their debt to My justice.",
    'prayer' => "Most Merciful Jesus, You Yourself have said that You desire mercy; so I bring into the abode of Your Most Compassionate Heart the souls in Purgatory, souls who are very dear to You, and yet, who must make retribution to Your justice. May the streams of Blood and Water which gushed forth from Your Heart put out the flames of the purifying fire, that in that place, too, the power of Your mercy may be praised.\n\nFrom that terrible heat of the cleansing fire rises a plaint to Your mercy, and they receive comfort, refreshment, relief in the stream of mingled Blood and Water.\n\nEternal Father, turn Your merciful gaze upon the souls suffering in Purgatory, who are enfolded in the Most Compassionate Heart of Jesus. I beg You, by the sorrowful Passion of Jesus Your Son, and by all the bitterness with which His most sacred Soul was flooded, manifest Your mercy to the souls who are under Your just scrutiny. Look upon them in no other way than through the Wounds of Jesus, Your dearly beloved Son; for we firmly believe that there is no limit to Your goodness and compassion. Amen.",
  ],
  9 => [
    'title' => 'Day 9 - Lukewarm Souls',
    'theme' => 'Lukewarm Souls',
    'weekday' => 6, // Saturday (second Saturday)
    'intention' => "Today bring to Me souls who have become lukewarm, and immerse them in the abyss of My mercy. These souls wound My Heart most painfully. My soul suffered the most dreadful loathing in the Garden of Olives because of lukewarm souls. They were the reason I cried out: \"Father, take this cup away from Me, if it be Your will.\" For them, the last hope of salvation is to flee to My mercy.",
    'prayer' => "Most Compassionate Jesus, You are Compassion Itself. I bring lukewarm souls into the abode of Your Most Compassionate Heart. In this fire of Your pure love let these tepid souls, who like corpses, filled You with such deep loathing, be once again set aflame. O Most Compassionate Jesus, exercise the omnipotence of Your mercy and draw them into the very ardor of Your love; and bestow upon them the gift of holy love, for nothing is beyond Your power.\n\nFire and ice cannot be joined. Either the fire dies, or the ice melts. But by Your mercy, O God, You can make up for all that is lacking.\n\nEternal Father, turn Your merciful gaze upon lukewarm souls, who are nonetheless enfolded in the Most Compassionate Heart of Jesus. Father of Mercy, I beg You by the bitter Passion of Your Son and by His three-hour agony on the Cross: let them, too, glorify the abyss of Your mercy. Amen.",
  ],
];

// Create novena day nodes.
foreach ($novena_days as $day_number => $data) {
  // Check if novena day already exists.
  $existing = \Drupal::entityTypeManager()
    ->getStorage('node')
    ->loadByProperties(['type' => 'novena_day', 'title' => $data['title']]);

  if (!empty($existing)) {
    echo "  Skipped novena day (exists): {$data['title']}\n";
    continue;
  }

  $node = Node::create([
    'type' => 'novena_day',
    'title' => $data['title'],
    'field_day_number' => $day_number,
    'field_theme' => $data['theme'],
    'field_weekday' => $data['weekday'],
    'field_intention' => [
      'value' => $data['intention'],
      'format' => 'basic_html',
    ],
    'field_prayer' => [
      'value' => $data['prayer'],
      'format' => 'basic_html',
    ],
    'status' => 1,
  ]);

  $node->save();
  echo "  Created novena day: {$data['title']}\n";
}

echo "\nImport complete!\n";
