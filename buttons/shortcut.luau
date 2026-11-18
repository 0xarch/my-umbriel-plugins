--!nonstrict
shortcut.setLabel(noctalia.tr("title"))
shortcut.setIcon("layout-grid")
shortcut.setActive(false)
shortcut.setEnabled(true)

function onClick()
  noctalia.togglePanel("io.soloev/buttons:drawer")
end
