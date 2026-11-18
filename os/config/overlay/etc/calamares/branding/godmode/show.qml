import QtQuick 2.5;
import calamares.slideshow 1.0;

Presentation {
    id: presentation

    Slide {
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 20
            color: "#f2f2f7"
            text: "Installing GodMode OS\n\nClaude Code, Chrome and Node 22 are already\npart of this system. Nothing to install after.\n\nThis takes a few minutes."
        }
    }

    function onActivate()   { }
    function onLeave()      { }
}
