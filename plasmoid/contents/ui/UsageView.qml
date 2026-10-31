import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami
import "SnapshotLogic.js" as SnapshotLogic

// Usage tab body, moved verbatim from FullRepresentation.qml.
ColumnLayout {
    id: usage

    spacing: Kirigami.Units.smallSpacing

    // Wall clock for the reset and retry countdowns; ticks only while open.
    property double nowMs: Date.now()

    Timer {
        interval: 30000
        repeat: true
        triggeredOnStart: true
        running: root.expanded
        onTriggered: usage.nowMs = Date.now()
    }

    PlasmaExtras.PlaceholderMessage {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: !root.hasData && root.lastError !== ""
        iconName: "network-disconnect"
        text: i18n("Couldn't load usage")
        explanation: root.lastError
    }

    PlasmaExtras.PlaceholderMessage {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: !root.hasData && root.lastError === ""
        iconName: "speedometer"
        text: i18n("Loading…")
    }

    PlasmaExtras.PlaceholderMessage {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: root.hasData
            && (root.snapshot.installed_provider_ids || []).length === 0
        iconName: "system-search"
        text: i18n("No supported tools detected")
        explanation: i18n(
            "Install or sign in to a supported AI coding tool, then refresh."
        )
    }

    PlasmaExtras.PlaceholderMessage {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: root.hasData
            && (root.snapshot.installed_provider_ids || []).length > 0
            && (root.snapshot.providers || []).length === 0
        iconName: "view-hidden"
        text: i18n("No tracked providers")
        explanation: i18n("Choose providers in the widget settings.")
    }

    QQC2.ScrollView {
        id: providerScroll
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: root.hasData && (root.snapshot.providers || []).length > 0
        contentWidth: availableWidth
        QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff
        QQC2.ScrollBar.vertical.policy: (root.snapshot.providers || []).length > 2
            ? QQC2.ScrollBar.AsNeeded : QQC2.ScrollBar.AlwaysOff

        ColumnLayout {
            width: providerScroll.availableWidth
            spacing: Kirigami.Units.largeSpacing

            Repeater {
                model: root.snapshot.providers || []

                delegate: ColumnLayout {
                    id: providerSection
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            source: root.providerIconSource(
                                providerSection.modelData.provider_id
                            )
                            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                            isMask: true
                            color: Kirigami.Theme.textColor
                        }
                        Kirigami.Heading {
                            Layout.fillWidth: true
                            level: 3
                            text: providerSection.modelData.display_name
                            elide: Text.ElideRight
                        }
                        PlasmaComponents.Label {
                            visible: !!providerSection.modelData.plan
                            text: providerSection.modelData.plan || ""
                            opacity: 0.65
                            elide: Text.ElideRight
                        }
                        Kirigami.Icon {
                            visible: providerSection.modelData.status === "stale"
                            source: "data-warning"
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            color: Kirigami.Theme.neutralTextColor
                        }
                    }

                    Kirigami.InlineMessage {
                        Layout.fillWidth: true
                        visible: providerSection.modelData.status !== "ok"
                        type: providerSection.modelData.status === "stale"
                            || providerSection.modelData.status === "rate_limited"
                            ? Kirigami.MessageType.Warning
                            : Kirigami.MessageType.Error
                        text: usage.failureText(providerSection.modelData, usage.nowMs)
                    }

                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: Kirigami.Units.smallSpacing
                        rowSpacing: Kirigami.Units.smallSpacing

                        Repeater {
                            model: providerSection.modelData.windows || []

                            delegate: Rectangle {
                                id: quotaCard
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.preferredWidth: (
                                    providerScroll.availableWidth
                                    - Kirigami.Units.smallSpacing
                                ) / 2
                                implicitHeight: quotaContent.implicitHeight
                                    + Kirigami.Units.largeSpacing * 2
                                radius: Kirigami.Units.smallSpacing
                                color: Qt.rgba(
                                    Kirigami.Theme.textColor.r,
                                    Kirigami.Theme.textColor.g,
                                    Kirigami.Theme.textColor.b,
                                    0.055
                                )

                                ColumnLayout {
                                    id: quotaContent
                                    anchors {
                                        left: parent.left
                                        right: parent.right
                                        top: parent.top
                                        margins: Kirigami.Units.largeSpacing
                                    }
                                    spacing: Kirigami.Units.smallSpacing

                                    RowLayout {
                                        Layout.fillWidth: true
                                        PlasmaComponents.Label {
                                            Layout.fillWidth: true
                                            text: quotaCard.modelData.caption
                                            opacity: 0.72
                                            elide: Text.ElideRight
                                        }
                                        PlasmaComponents.Label {
                                            text: Math.round(root.displayedPercent(
                                                Number(quotaCard.modelData.used_percent)
                                            )) + "%"
                                            font.bold: true
                                            color: root.valueColor(
                                                Number(quotaCard.modelData.used_percent)
                                            )
                                        }
                                    }

                                    Rectangle {
                                        Layout.fillWidth: true
                                        height: Math.round(Kirigami.Units.gridUnit * 0.35)
                                        radius: height / 2
                                        color: Qt.rgba(
                                            Kirigami.Theme.textColor.r,
                                            Kirigami.Theme.textColor.g,
                                            Kirigami.Theme.textColor.b,
                                            0.14
                                        )

                                        Rectangle {
                                            width: parent.width * Math.max(
                                                0,
                                                Math.min(
                                                    1,
                                                    root.displayedPercent(
                                                        Number(
                                                            quotaCard.modelData.used_percent
                                                        )
                                                    ) / 100
                                                )
                                            )
                                            height: parent.height
                                            radius: height / 2
                                            color: root.barColor(
                                                Number(quotaCard.modelData.used_percent)
                                            )
                                            Behavior on width {
                                                NumberAnimation {
                                                    duration: 250
                                                    easing.type: Easing.OutCubic
                                                }
                                            }
                                        }
                                    }

                                    PlasmaComponents.Label {
                                        visible: text !== ""
                                        text: usage.relativeReset(
                                            quotaCard.modelData.resets_at,
                                            usage.nowMs
                                        )
                                        opacity: 0.55
                                        font: Kirigami.Theme.smallFont
                                    }
                                }
                            }
                        }

                        Rectangle {
                            id: billingCard
                            visible: !!providerSection.modelData.billing_usage
                            Layout.fillWidth: true
                            Layout.preferredWidth: (
                                providerScroll.availableWidth
                                - Kirigami.Units.smallSpacing
                            ) / 2
                            implicitHeight: billingColumn.implicitHeight
                                + Kirigami.Units.largeSpacing * 2
                            radius: Kirigami.Units.smallSpacing
                            color: Qt.rgba(
                                Kirigami.Theme.textColor.r,
                                Kirigami.Theme.textColor.g,
                                Kirigami.Theme.textColor.b,
                                0.055
                            )

                            ColumnLayout {
                                id: billingColumn
                                anchors {
                                    left: parent.left
                                    right: parent.right
                                    top: parent.top
                                    margins: Kirigami.Units.largeSpacing
                                }
                                PlasmaComponents.Label {
                                    text: usage.billingTitle(
                                        providerSection.modelData.billing_usage
                                    )
                                    opacity: 0.72
                                }
                                PlasmaComponents.Label {
                                    text: usage.billingValue(
                                        providerSection.modelData.billing_usage
                                    )
                                    font.bold: true
                                }
                            }
                        }
                    }

                    Kirigami.Separator {
                        Layout.fillWidth: true
                        opacity: 0.45
                    }
                }
            }
        }
    }

    function failureText(providerData, nowMs) {
        var text = providerData.error_message || providerData.status
        if (providerData.status === "stale")
            text = i18n("Showing the last successful reading. %1", text)
        var retry = relativeRetry(providerData.retry_at, nowMs)
        if (retry !== "")
            text += " " + retry
        return text
    }

    function relativeReset(iso, nowMs) {
        var difference = SnapshotLogic.millisUntil(iso, nowMs)
        if (difference === null)
            return ""
        if (difference <= 0)
            return i18n("Resetting…")
        var minutes = Math.max(1, Math.round(difference / 60000))
        if (minutes < 60)
            return i18np("Resets in %1 minute", "Resets in %1 minutes", minutes)
        var hours = Math.floor(minutes / 60)
        if (hours < 24)
            return i18n("Resets in %1h %2m", hours, minutes % 60)
        var days = Math.floor(hours / 24)
        return i18n("Resets in %1d %2h", days, hours % 24)
    }

    function relativeRetry(iso, nowMs) {
        var difference = SnapshotLogic.millisUntil(iso, nowMs)
        if (difference === null)
            return ""
        if (difference <= 0)
            return i18n("Ready to retry.")
        var minutes = Math.max(1, Math.ceil(difference / 60000))
        if (minutes < 60)
            return i18np("Retry in %1 minute.", "Retry in %1 minutes.", minutes)
        return i18n("Retry in %1h %2m.", Math.floor(minutes / 60), minutes % 60)
    }

    function billingTitle(billing) {
        return billing && billing.kind === "flex_credit_balance"
            ? i18n("Credits") : i18n("Extra Usage")
    }

    function billingValue(billing) {
        if (!billing)
            return ""
        if (billing.kind === "bounded_spend") {
            var used = Number(billing.used_amount || 0)
            var limit = Number(billing.limit_amount || 0)
            var value = root.usageMode === "used" ? used : Math.max(limit - used, 0)
            return "$" + value.toFixed(2)
                + (root.usageMode === "used" ? " / $" + limit.toFixed(2) : "")
        }
        if (billing.kind === "unbounded_spend")
            return "$" + Number(billing.used_amount || 0).toFixed(2)
        if (billing.kind === "flex_credit_balance")
            return i18n(
                "%1 (~$%2)",
                billing.remaining_credits,
                Number(billing.usd_value || 0).toFixed(2)
            )
        return ""
    }
}
