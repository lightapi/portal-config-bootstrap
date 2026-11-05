"""Explicit release download capabilities required by this repository."""
import portal_view_download_contract as contract


class DownloadTests(contract.SourceContract, contract.StageContract, contract.PrepareContract, contract.DownloadFixture):
    pass
