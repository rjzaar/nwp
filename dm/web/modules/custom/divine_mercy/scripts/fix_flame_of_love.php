<?php
/**
 * Fix Flame of Love reflections with correct USCCB content.
 */

use Drupal\node\Entity\Node;

// Node ID for Flame of Love Reflections
$node_id = 27;

// USCCB content for 5 decades (extracted from source.htm)
$decades = [
  1 => [
    "My heart is nearly broken with sorrow; stay here and keep watch with Me.",
    "Help us to bear witness by following Christ's example of suffering.",
    "Here I am, Lord. I come to do Your will. (Ps 40:7-8)",
    "You have redeemed us with your precious blood; hear the prayer of Your servants and come to our help.",
    "My soul is in anguish, My heart is in torment.",
    "Father, if this cup may not pass, but I must drink it, then Your will be done. (Mt 26:42)",
    "Through her heart, His sorrow sharing, All His bitter anguish bearing.",
    "Be glad to share in the sufferings of Christ! When He comes in glory, you will be filled with joy. (1 Pt 4:13)",
    "Grant that we may bring love and comfort to our brothers and sisters in distress.",
    "For the sake of you, who left a garden, I was betrayed in a garden.",
  ],
  2 => [
    "It is by His wounds that we are healed. (Is 53:5)",
    "The soldiers took Jesus inside the palace and called the whole cohort together. (Mk 15:16)",
    "They clothed Him in purple, and weaving a crown of thorns, placed it on Him. (Mk 15:17)",
    "Carrying the cross by Himself, He went out to what is called The Place of the Skull. (Jn 19:17)",
    "He himself bore our sins in His body upon the cross. (1 Pt 2:24)",
    "Was crucified also for us under Pontius Pilate; He suffered and was buried.",
    "Even though I walk in the dark valley I fear no evil; for You are at My side. (Ps 23:4)",
    "Through her heart, His sorrow sharing, All His bitter anguish bearing.",
    "Here I am Lord; I have come to do Your will. (Ps 40:8-9)",
    "The king of glory draws near; the gate must be lifted up!",
  ],
  3 => [
    "They clothed Him in purple, and weaving a crown of thorns, placed it on Him. (Mk 15:17)",
    "And kneeling before Him, they mocked Him, saying, 'Hail, King of the Jews!' (Mt 27:29)",
    "Pilate brought Jesus out and seated Him on the judge's bench. (Jn 19:13)",
    "And Pilate said to them, 'Behold your king!' (Jn 19:14)",
    "Take Him yourselves and crucify Him. I find no guilt in Him. (Jn 19:6)",
    "Pilate said to them, Shall I crucify your king? (Jn 19:15)",
    "Through her heart, His sorrow sharing, All His bitter anguish bearing.",
    "We adore You, O Christ, and we bless You, because by Your holy cross You have redeemed the world.",
    "Grant that we may bring love and comfort to our brothers and sisters in distress.",
    "For the sake of you, who left a garden, I was betrayed in a garden.",
  ],
  4 => [
    "Carrying the cross by Himself, He went out to what is called the Place of the Skull. (Jn 19:17)",
    "If anyone wishes to come after Me, he must deny himself, take up his cross, and follow Me. (Mt 16:24)",
    "A large crowd of people followed Jesus, including many women who mourned and lamented Him. (Lk 23:27)",
    "We adore You, O Christ, and we bless You, because by Your holy cross You have redeemed the world.",
    "My sacrifice, O God, is a contrite spirit; a heart contrite and humbled, O God, You will not spurn. (Ps 51:19)",
    "Through her heart, His sorrow sharing, All His bitter anguish bearing.",
    "For the sake of His sorrowful passion, have mercy on us and on the whole world.",
    "Lord by Your cross and resurrection, You have set us free. You are the Savior of the world.",
    "Grant that we may bring love and comfort to our brothers and sisters in distress.",
    "Here I am Lord; I have come to do Your will. (Ps 40:8-9)",
  ],
  5 => [
    "There they crucified Him, and with Him two others, one on either side, with Jesus in the middle. (Jn 19:18)",
    "We adore You, O Christ, and we bless You, because by Your holy cross You have redeemed the world.",
    "Into Your hands I commend My spirit; You will redeem Me, O Lord, O faithful God. (Ps 31:6)",
    "You have redeemed us with Your precious blood; hear the prayer of Your servants and come to our help.",
    "Lord, by Your cross and resurrection, You have set us free. You are the Savior of the world.",
    "Through her heart, His sorrow sharing, All His bitter anguish bearing.",
    "Christ suffered for you, and left you an example, that you should follow in His steps. (1 Pt 2:21)",
    "Father, forgive them, for they know not what they do. (Lk 23:34)",
    "Amen, I say to you, today you will be with Me in Paradise. (Lk 23:43)",
    "Woman, behold, your son... Behold, your mother. (Jn 19:26-27)",
  ],
];

$node = Node::load($node_id);
if (!$node) {
  echo "Node $node_id not found!\n";
  exit(1);
}

// Update decade reflections
$decade_values = [];
foreach ($decades as $decade_num => $reflections) {
  $decade_values[] = implode("\n", $reflections);
}

$node->set('field_decade_reflections', $decade_values);
$node->save();

echo "Updated Flame of Love Reflections (node $node_id) with correct USCCB content.\n";
echo "Decade 1 preview: " . substr($decades[1][0], 0, 60) . "...\n";
