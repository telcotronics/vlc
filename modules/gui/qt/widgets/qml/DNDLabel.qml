/*****************************************************************************
 * Copyright (C) 2019 VLC authors and VideoLAN
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * ( at your option ) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/
import QtQuick 2.11
import QtQuick.Controls 2.4
import QtQuick.Layouts 1.3
import QtGraphicalEffects 1.0
import org.videolan.vlc 0.1

import "qrc:///widgets/" as Widgets
import "qrc:///playlist/" as Playlist
import "qrc:///style/"

Playlist.PlaylistDroppable {
    property alias text: label.text
    property alias model: plitem.model
    property alias color: bg.color
    property VLCColors _colors: VLCStyle.colors

    z: 1
    width:  plitem.visible ? plitem.width : label.width
    height: plitem.visible ? plitem.height : label.height
    opacity: 0.75
    visible: false

    Rectangle {
        id: bg

        anchors.fill: parent
        color: _colors.button
        border.color : _colors.buttonBorder
        radius: 6
    }

    Drag.active: visible

    property var count: 0

    property point _pos: null

    function updatePos(x, y) {
        var pos = root.mapFromGlobal(x, y)
        dragItem.x = pos.x
        dragItem.y = pos.y

        // since we override position update during dragging with updatePos(),
        // it is better to track the final position through a property:
        _pos = pos
    }

    RectangularGlow {
        anchors.fill: parent
        glowRadius: VLCStyle.dp(8, VLCStyle.scale)
        color: _colors.glowColor
        spread: 0.2
    }

    Text {
        id: label
        width: implicitWidth + VLCStyle.dp(10, VLCStyle.scale)
        height: implicitHeight + VLCStyle.dp(10, VLCStyle.scale)
        font.pixelSize: VLCStyle.fontSize_normal
        color: _colors.text
        text: i18n.qtr("%1 tracks selected").arg(count)
        visible: count > 1 || !model
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
    }

    Item {
        id: plitem
        visible: count === 1 && model
        width: childrenRect.width
        height: childrenRect.height

        property var model

        RowLayout {
            id: content
            width: implicitWidth + VLCStyle.dp(10, VLCStyle.scale)
            height: implicitHeight + VLCStyle.dp(10, VLCStyle.scale)
            Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter

            Item {
                Layout.preferredHeight: VLCStyle.icon_normal
                Layout.preferredWidth: VLCStyle.icon_normal
                Layout.leftMargin: VLCStyle.margin_xsmall

                Image {
                    id: artwork
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectFit
                    source: (model && model.artwork && model.artwork.toString()) ? model.artwork : VLCStyle.noArtCover
                    visible: !statusIcon.visible
                }

                Widgets.IconLabel {
                    id: statusIcon
                    anchors.fill: parent
                    visible: (!!model && model.isCurrent && text !== "")
                    width: height
                    height: VLCStyle.icon_normal
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    color: _colors.accent
                    text: player.playingState === PlayerController.PLAYING_STATE_PLAYING ? VLCIcons.volume_high :
                                                    player.playingState === PlayerController.PLAYING_STATE_PAUSED ? VLCIcons.pause :
                                                        player.playingState === PlayerController.PLAYING_STATE_STOPPED ? VLCIcons.stop : ""
                }
            }

            Column {
                Widgets.ListLabel {
                    id: textInfo
                    Layout.leftMargin: VLCStyle.margin_small

                    font.weight: model && model.isCurrent ? Font.DemiBold : Font.Normal
                    text: model ? model.title : ""
                    color: _colors.text
                }

                Widgets.ListSubtitleLabel {
                    id: textArtist
                    Layout.leftMargin: VLCStyle.margin_small

                    font.weight: (model && model.isCurrent) ? Font.DemiBold : Font.Normal
                    text: ((model && model.artist) ? model.artist : i18n.qtr("Unknown Artist"))
                    color: _colors.text
                }
            }

            Widgets.ListLabel {
                id: textDuration
                Layout.rightMargin: VLCStyle.margin_xsmall

                text: model ? model.duration : ""
                color: _colors.text
            }
        }
    }
}
